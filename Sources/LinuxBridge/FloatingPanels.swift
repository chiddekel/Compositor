import Foundation

/// Upstream's floating panels. On the Mac, `ContentView` watches the session and shows an `NSPanel`
/// (`FloatingPanel`) for each editing task — a layer effect, … — and runs the task's cancel when the panel's close
/// button is pressed. The Qt shell has no ContentView: the state tells it which of these panels should be up (the shell
/// shows each one as a non-modal tool window rendering the upstream view), and `close` is the close button.
enum FloatingPanels {
    struct Open: Encodable, Equatable {
        /// SwiftUI panel name the shell renders (see SwiftUIBridge.resolvePanel).
        let panel: String
        /// Window title, as upstream passes it to `FloatingPanel.show(title:)`.
        let title: String
    }

    /// ContentView's own bookkeeping that isn't a panel: runs before each state read, as its `.onChange` handlers do
    /// after every change.
    @MainActor static func observe(_ editor: UpstreamEditor) {
        let session = editor.session
        if session.filterEdit == nil { editor.filterInShellDialog = false }
        // .onChange(of: session.document?.layers): an effect deleted (or its layer gone) while being edited ends the edit.
        if let editing = session.effectsEditing,
           session.document?.layers.first(where: { $0.id == editing.layerID })?.effects?.contains(editing.kind) != true {
            if let picker = session.colorPicker, case .effect = picker.target { session.closeColorPicker(commit: false) }
            session.effectsEditing = nil
            session.effectsEditingOriginal = nil
        }
    }

    /// The panels ContentView would be showing now.
    @MainActor static func open(in editor: UpstreamEditor) -> [Open] {
        let session = editor.session
        var panels: [Open] = []
        if let editing = session.effectsEditing { panels.append(Open(panel: "EffectsSheet", title: editing.kind.rawValue)) }
        if let picker = session.colorPicker { panels.append(Open(panel: "ColorPickerSheet", title: picker.target.title)) }
        if session.levels != nil { panels.append(Open(panel: "LevelsSheet", title: "Levels")) }
        if session.hueSaturation != nil { panels.append(Open(panel: "HueSaturationSheet", title: "Hue/Saturation")) }
        if let operation = session.selectionAmountOperation {
            panels.append(Open(panel: "SelectionAmountSheet", title: operation.rawValue + " Selection"))
        }
        if !editor.filterInShellDialog, let edit = session.filterEdit { panels.append(Open(panel: "FilterSheet", title: edit.kind.rawValue)) }
        if ShortcutSettings.shared.sheet != nil { panels.append(Open(panel: "KeyboardShortcutsSheet", title: "Keyboard Shortcuts")) }
        return panels
    }

    /// The panel's close button: what ContentView sets as that panel's `onClose`.
    @MainActor static func close(_ panel: String, in editor: UpstreamEditor) {
        let session = editor.session
        switch panel {
        case "EffectsSheet": if session.effectsEditing != nil { session.finishEffectsEditing(commit: false) }
        case "FilterSheet": if session.filterEdit != nil { session.cancelFilter() }
        case "ColorPickerSheet": if session.colorPicker != nil { session.closeColorPicker(commit: false) }
        case "LevelsSheet": if session.levels != nil { session.cancelLevels() }
        case "HueSaturationSheet": if session.hueSaturation != nil { session.cancelHueSaturation() }
        case "SelectionAmountSheet": session.selectionAmountOperation = nil
        case "KeyboardShortcutsSheet": ShortcutSettings.shared.close()
        default: break
        }
    }
}
