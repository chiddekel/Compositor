#pragma once
// AppKit's Hide Others / Show All on the desktop's window manager. AppKit hides every other application and
// later unhides them; an X11 client can ask the window manager to iconify another client's top-level window
// (ICCCM WM_CHANGE_STATE) and to map it again. Wayland gives a client no access to other clients' windows,
// so there Hide Others is unavailable and Show All has nothing of another application's to restore.
#include <QApplication>
#include <QGuiApplication>
#include <QSet>
#include <QVector>
#include <QWidget>
#include <QWindow>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#if __has_include(<xcb/xcb.h>) && QT_CONFIG(xcb)
#include <xcb/xcb.h>
#define COMPOSITOR_HAS_XCB_APPLICATIONS 1
#endif

namespace OtherApplications {

#if defined(COMPOSITOR_HAS_XCB_APPLICATIONS)
inline xcb_connection_t *connection() {
    auto *x11 = qGuiApp ? qGuiApp->nativeInterface<QNativeInterface::QX11Application>() : nullptr;
    return x11 ? x11->connection() : nullptr;
}

inline xcb_atom_t atom(xcb_connection_t *c, const char *name) {
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(c, xcb_intern_atom(c, 0, uint16_t(strlen(name)), name), nullptr);
    const xcb_atom_t result = reply ? reply->atom : XCB_ATOM_NONE;
    free(reply);
    return result;
}

/// A 32-bit-format property (window lists, atoms, cardinals) of `window`; empty when absent.
inline QVector<uint32_t> property32(xcb_connection_t *c, xcb_window_t window, const char *name) {
    QVector<uint32_t> values;
    xcb_get_property_reply_t *reply = xcb_get_property_reply(c,
        xcb_get_property(c, 0, window, atom(c, name), XCB_GET_PROPERTY_TYPE_ANY, 0, 16384), nullptr);
    if (reply && reply->format == 32) {
        const auto *data = static_cast<const uint32_t *>(xcb_get_property_value(reply));
        values = QVector<uint32_t>(data, data + xcb_get_property_value_length(reply) / 4);
    }
    free(reply);
    return values;
}

inline xcb_window_t root(xcb_connection_t *c) { return xcb_setup_roots_iterator(xcb_get_setup(c)).data->root; }

/// Hidden (what AppKit's hidden application windows become here): EWMH _NET_WM_STATE_HIDDEN when the window
/// manager maintains it, else ICCCM WM_STATE IconicState (3). Mutter reports WM_STATE Iconic for windows it shows.
inline bool isIconic(xcb_connection_t *c, xcb_window_t window) {
    const xcb_atom_t hidden = atom(c, "_NET_WM_STATE_HIDDEN");
    if (property32(c, root(c), "_NET_SUPPORTED").contains(hidden))
        return property32(c, window, "_NET_WM_STATE").contains(hidden);
    const QVector<uint32_t> state = property32(c, window, "WM_STATE");
    return !state.isEmpty() && state.first() == 3;
}

/// Managed top-level windows of other applications: not this process's, not the desktop or its panels.
inline QVector<xcb_window_t> otherClientWindows(xcb_connection_t *c) {
    QSet<uint32_t> own;
    for (QWidget *widget : QApplication::topLevelWidgets())
        if (widget->windowHandle()) own.insert(uint32_t(widget->winId()));
    const uint32_t pid = uint32_t(getpid());
    const xcb_atom_t dock = atom(c, "_NET_WM_WINDOW_TYPE_DOCK"), desktop = atom(c, "_NET_WM_WINDOW_TYPE_DESKTOP");
    QVector<xcb_window_t> windows;
    for (uint32_t window : property32(c, root(c), "_NET_CLIENT_LIST")) {
        if (own.contains(window)) continue;
        const QVector<uint32_t> owner = property32(c, window, "_NET_WM_PID");
        if (!owner.isEmpty() && owner.first() == pid) continue;
        const QVector<uint32_t> types = property32(c, window, "_NET_WM_WINDOW_TYPE");
        if (types.contains(dock) || types.contains(desktop)) continue;
        windows << window;
    }
    return windows;
}

/// Windows this application hid; Show All restores only these, never windows the user minimized.
inline QVector<xcb_window_t> &hiddenByUs() { static QVector<xcb_window_t> windows; return windows; }
#endif

/// True when the window system lets this client hide other applications (an X11 session with a window manager).
inline bool canHideOthers() {
#if defined(COMPOSITOR_HAS_XCB_APPLICATIONS)
    xcb_connection_t *c = connection();
    return c && !property32(c, root(c), "_NET_SUPPORTING_WM_CHECK").isEmpty();
#else
    return false;
#endif
}

/// Hide Others: iconify every visible top-level window of other applications.
inline int hideOthers() {
#if defined(COMPOSITOR_HAS_XCB_APPLICATIONS)
    xcb_connection_t *c = connection();
    if (!c || !canHideOthers()) return 0;
    const xcb_atom_t change = atom(c, "WM_CHANGE_STATE");
    int hidden = 0;
    for (xcb_window_t window : otherClientWindows(c)) {
        if (isIconic(c, window)) continue;
        xcb_client_message_event_t event{};
        event.response_type = XCB_CLIENT_MESSAGE;
        event.format = 32;
        event.window = window;
        event.type = change;
        event.data.data32[0] = 3;   // IconicState
        xcb_send_event(c, 0, root(c), XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
                       reinterpret_cast<const char *>(&event));
        if (!hiddenByUs().contains(window)) hiddenByUs() << window;
        hidden++;
    }
    xcb_flush(c);
    return hidden;
#else
    return 0;
#endif
}

/// Show All: map again the other applications' windows Hide Others iconified (and that are still iconic).
inline int showAll() {
#if defined(COMPOSITOR_HAS_XCB_APPLICATIONS)
    xcb_connection_t *c = connection();
    if (!c) { return 0; }
    const QVector<xcb_window_t> live = otherClientWindows(c);
    int shown = 0;
    for (xcb_window_t window : hiddenByUs()) {
        if (!live.contains(window) || !isIconic(c, window)) continue;
        xcb_map_window(c, window);
        shown++;
    }
    hiddenByUs().clear();
    xcb_flush(c);
    return shown;
#else
    return 0;
#endif
}

} // namespace OtherApplications
