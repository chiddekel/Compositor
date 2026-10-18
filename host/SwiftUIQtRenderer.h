// SwiftUIQtRenderer — builds a real Qt widget tree from `compositor_session_render_tree`'s JSON, one generic
// interpreter for every panel instead of a hand-mirrored Qt reimplementation per panel. See
// docs/platform-abstraction.md and the "Generic SwiftUI→Qt compat runtime" plan.
#pragma once

#include <QString>
#include <QWidget>
#include <QIcon>
#include <QColor>
#include <cstdint>

#include <functional>

/// Writes `svg` once to a runtime file and returns its path, for `image: url(...)` in style sheets.
QString styleSheetImage(const QString &name, const QByteArray &svg);

/// Parses a color token string (e.g. "accentColor", "rgb:r,g,b,a", hex, etc.)
QColor parseColorToken(const QString &name);

/// Renders SF Symbol vector icons into a QIcon.
QIcon renderToolVectorIcon(const QString &symbol, int size = 20, const QColor &color = QColor(0xf5, 0xf5, 0xf7));

/// Renders `panel` (a name `Sources/LinuxBridge/SwiftUIBridge.swift` recognises, e.g. "NavigationToolHeader")
/// against the session `sessionHandle` already identifies, as a standalone (unparented) `QWidget` tree. Returns
/// `nullptr` if the panel name is unknown to the Swift side, the session handle is invalid, or the tree is empty.
QWidget *swiftUIRenderPanel(uint64_t sessionHandle, const QString &panel);
/// Like `swiftUIRenderPanel`, but returns `current` itself (repainted, not rebuilt) when the panel's resolved tree is
/// byte-for-byte the one `current` was built from — most state changes leave most panels untouched.
QWidget *swiftUIRenderPanelIfChanged(uint64_t sessionHandle, const QString &panel, QWidget *current);

/// Registers a listener called immediately after any SwiftUI action handler finishes dispatching.
void registerSwiftUIActionListener(std::function<void(uint64_t handle, const QString &panel)> listener);

/// True while a SwiftUI DragGesture is tracking the pointer (hue/SB field, levels, …).
bool swiftUIDragGestureActive(uint64_t sessionHandle);

/// True while an AppKit tracking loop (a press in an `_AppKit` view) runs the event pump: the shell's periodic refresh
/// waits, so no panel is rebuilt under the press.
bool swiftUIAppKitTracking();
/// Bounded geometry/focus diagnostics recorded by native tests or COMPOSITOR_TRACE_SCROLL_BUFFER.
QString swiftUIScrollTrace();
/// Bounded native pointer delivery diagnostics recorded by native tests or COMPOSITOR_TRACE_POINTER_BUFFER.
QString swiftUIPointerTrace();
void swiftUITraceWindowKey(const void *owner, uint64_t handle, int code, int modifiers);
