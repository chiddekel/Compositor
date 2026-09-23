import Foundation

/// The questions upstream's importer asks through SwiftUI sheets, answered by the Qt shell instead.
///
/// `EditorSession` exposes a hook for each (`confirmConversions`, `confirmRawDevelop` — what upstream's own tests use to
/// run without a sheet). The Photoshop one ("these layers will be converted — import anyway?") goes to a callback the
/// shell registers and shows as a dialog. RAW files develop with the camera's own settings: upstream's Develop sheet
/// (exposure, white balance, ... with a live preview) has no Qt counterpart yet.
enum ImportPrompts {
    /// Shell callback: a JSON array of {"layer","message"} and its length; returns non-zero to go ahead.
    typealias ConversionPrompt = @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
    nonisolated(unsafe) static var conversionPrompt: ConversionPrompt?

    @MainActor static func install(on session: EditorSession) {
        if session.confirmConversions == nil {
            session.confirmConversions = { conversions in
                guard let prompt = conversionPrompt else { return true }
                let rows = conversions.map { ["layer": $0.layerName, "message": $0.message] }
                guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return true }
                return data.withUnsafeBytes { raw in
                    prompt(raw.bindMemory(to: UInt8.self).baseAddress, data.count) != 0
                }
            }
        }
        if session.confirmRawDevelop == nil {
            session.confirmRawDevelop = { _, asShot in asShot }
        }
    }
}

@_cdecl("compositor_set_conversion_prompt")
nonisolated public func compositorSetConversionPrompt(_ prompt: (@convention(c) (UnsafePointer<UInt8>?, Int) -> Int32)?) {
    ImportPrompts.conversionPrompt = prompt
}
