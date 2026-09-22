// TEMP STAND-IN for `View.footerHitArea()`, real upstream code living in Compositor/UI/LayersPanel.swift (not
// wired in yet — it needs NativeLayerList.swift, 1101 lines of real NSTableView bridging, the genuine
// NSViewRepresentable escape hatch). Remove this file once LayersPanel.swift joins the Linux build for real.

import SwiftUI

extension View {
    /// Makes a small footer icon easier to click; the padding supplies the larger hit area.
    func footerHitArea() -> some View { padding(.horizontal, 8).padding(.vertical, 12) }
}
