// Linux addition: the layer rename field the SwiftUI layers list used before tip's own table (NativeLayerList.swift)
// was drawn by the shell. Tip renames in the row's NSTextField (LayerCell.beginRenaming); this view is kept only for
// Tests/LinuxOverrideTests/LayerRenameProbeTests.swift.

import Foundation
import SwiftUI

/// LayerCell's rename: Return or ending editing keeps the name; Escape restores it.
/// Tip 8f7d344: same size as the label, layer-row background (quaternary), not a bezeled field.
struct LayerRenameField: View {
    let session: EditorSession
    let layerID: UUID
    @State private var text: String
    @FocusState private var focused: Bool
    init(session: EditorSession, layerID: UUID, name: String) {
        self.session = session; self.layerID = layerID
        _text = State(initialValue: name)
    }
    var body: some View {
        TextField("Layer name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(keeping: true) }
            .onExitCommand { finish(keeping: false) }
            .onChange(of: focused) { _, focused in if !focused { finish(keeping: true) } }
    }

    private func finish(keeping: Bool) {
        guard session.renamingLayerID == layerID else { return }
        if keeping { session.renameLayer(layerID, to: text) }
        session.renamingLayerID = nil
        focused = false
    }
}
