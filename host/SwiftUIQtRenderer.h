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

