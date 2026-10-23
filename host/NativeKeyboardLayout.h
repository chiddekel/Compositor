#pragma once

#include <QGuiApplication>
#include <QtGui/qguiapplication_platform.h>
#include <QString>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-x11.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <xkbcommon/xkbcommon-names.h>
#include <sys/mman.h>
#include <unistd.h>

// Only this platform adapter owns XKB and Wayland objects. The Swift/AppKit boundary receives strings.
namespace nativekeyboard {
class WaylandKeymap final {
    wl_display *display = nullptr;
    wl_registry *registry = nullptr;
    wl_seat *seat = nullptr;
    wl_keyboard *keyboard = nullptr;
    xkb_context *context = nullptr;
    xkb_keymap *map = nullptr;

    static void keymap(void *data, wl_keyboard *, uint32_t format, int32_t fd, uint32_t size) {
        auto &self = *static_cast<WaylandKeymap *>(data);
        if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && size) {
            void *bytes = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
            if (bytes != MAP_FAILED) {
                auto *next = xkb_keymap_new_from_buffer(self.context, static_cast<const char *>(bytes), size - 1,
                    XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
                munmap(bytes, size);
                if (next) { xkb_keymap_unref(self.map); self.map = next; }
            }
        }
        close(fd);
    }
    static void global(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t) {
        auto &self = *static_cast<WaylandKeymap *>(data);
        if (!self.seat && QByteArray(interface) == wl_seat_interface.name) {
            self.seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
            static const wl_seat_listener listener{
                [](void *data, wl_seat *seat, uint32_t capabilities) {
                    auto &self = *static_cast<WaylandKeymap *>(data);
                    if (self.keyboard || !(capabilities & WL_SEAT_CAPABILITY_KEYBOARD)) return;
                    self.keyboard = wl_seat_get_keyboard(seat);
                    static const wl_keyboard_listener keys{
                        keymap,
                        [](void *, wl_keyboard *, uint32_t, wl_surface *, wl_array *) {},
                        [](void *, wl_keyboard *, uint32_t, wl_surface *) {},
                        [](void *, wl_keyboard *, uint32_t, uint32_t, uint32_t, uint32_t) {},
                        [](void *, wl_keyboard *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) {},
                        [](void *, wl_keyboard *, int32_t, int32_t) {}};
                    wl_keyboard_add_listener(self.keyboard, &keys, &self);
                },
                [](void *, wl_seat *, const char *) {}};
            wl_seat_add_listener(self.seat, &listener, &self);
        }
    }
public:
    WaylandKeymap() {
        context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        display = wl_display_connect(nullptr);
        if (!display) return;
        registry = wl_display_get_registry(display);
        static const wl_registry_listener listener{global, [](void *, wl_registry *, uint32_t) {}};
        wl_registry_add_listener(registry, &listener, this);
        // Registry, seat capabilities, and keyboard map arrive in successive protocol exchanges.
        for (int i = 0; i < 3 && !map; ++i) if (wl_display_roundtrip(display) < 0) break;
    }
    ~WaylandKeymap() {
        if (keyboard) wl_keyboard_destroy(keyboard);
        if (seat) wl_seat_destroy(seat);
        if (registry) wl_registry_destroy(registry);
        if (display) wl_display_disconnect(display);
        xkb_keymap_unref(map);
        xkb_context_unref(context);
    }
    xkb_keymap *current() {
        if (display && wl_display_roundtrip(display) < 0) return nullptr;
        return map ? xkb_keymap_ref(map) : nullptr;
    }
};

inline xkb_keymap *currentKeymap(xkb_context *context) {
    if (QGuiApplication::platformName().startsWith("wayland")) {
        static WaylandKeymap wayland;
        return wayland.current();
    }
#if QT_CONFIG(xcb)
    if (auto *native = qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
        auto *connection = native->connection();
        if (!xkb_x11_setup_xkb_extension(connection, XKB_X11_MIN_MAJOR_XKB_VERSION, XKB_X11_MIN_MINOR_XKB_VERSION,
            XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS, nullptr, nullptr, nullptr, nullptr)) return nullptr;
        const int device = xkb_x11_get_core_keyboard_device_id(connection);
        if (device >= 0) return xkb_x11_keymap_new_from_device(context, connection, device, XKB_KEYMAP_COMPILE_NO_FLAGS);
    }
#endif
    return nullptr;
}

struct LatinKey {
    QByteArray physicalName;
    QString normal;
    QString shifted;
};

inline LatinKey lookupLatinKey(uint32_t code) {
    LatinKey result;
    auto *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!context) return {};
    auto *map = currentKeymap(context);
    if (map) result.physicalName = xkb_keymap_key_get_name(map, code);
    xkb_layout_index_t chosen = XKB_LAYOUT_INVALID;
    if (map) {
        for (xkb_layout_index_t layout = 0; layout < xkb_keymap_num_layouts(map); ++layout) {
            uint32_t letters = 0;
            for (auto key = xkb_keymap_min_keycode(map); key <= xkb_keymap_max_keycode(map); ++key) {
                const xkb_keysym_t *symbols = nullptr;
                const int count = xkb_keymap_key_get_syms_by_level(map, key, layout, 0, &symbols);
                for (int i = 0; i < count; ++i)
                    if (symbols[i] >= XKB_KEY_a && symbols[i] <= XKB_KEY_z) letters |= 1u << (symbols[i] - XKB_KEY_a);
            }
            if (letters == (1u << 26) - 1) { chosen = layout; break; }
        }
    }
    // Qt also supplies a US shortcut fallback when the compositor advertises only non-Latin layouts.
    if (chosen == XKB_LAYOUT_INVALID) {
        xkb_keymap_unref(map);
        xkb_rule_names names{}; names.layout = "us";
        map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
        chosen = 0;
    }
    if (map) {
        if (auto *state = xkb_state_new(map)) {
            const auto index = xkb_keymap_mod_get_index(map, XKB_MOD_NAME_SHIFT);
            for (bool shifted : {false, true}) {
                const xkb_mod_mask_t modifiers = shifted && index != XKB_MOD_INVALID ? (1u << index) : 0;
                xkb_state_update_mask(state, modifiers, 0, 0, 0, 0, chosen);
                char buffer[64]{};
                const int count = xkb_state_key_get_utf8(state, code, buffer, sizeof(buffer));
                if (count > 0 && count < int(sizeof(buffer)))
                    (shifted ? result.shifted : result.normal) = QString::fromUtf8(buffer, count);
            }
            xkb_state_unref(state);
        }
    }
    xkb_keymap_unref(map);
    xkb_context_unref(context);
    return result;
}

inline QString latinCharacter(uint32_t code, bool shifted) {
    const auto key = lookupLatinKey(code);
    return shifted ? key.shifted : key.normal;
}
}
