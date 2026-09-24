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
    /// Shell callback that presents a SwiftUI sheet panel (e.g. "RawDevelopSheet") modally until upstream closes it.
    typealias SheetPresenter = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    nonisolated(unsafe) static var sheetPresenter: SheetPresenter?
    nonisolated(unsafe) static var sheetPresenterContext: UnsafeMutableRawPointer?
    nonisolated(unsafe) static var presenting = false
    /// Shell callback run while a long command (a RAW develop, a big Photoshop file) works off the main thread: repaints
    /// and shows progress, without taking input, so the window doesn't freeze.
    typealias WaitPump = @convention(c) (UnsafeMutableRawPointer?) -> Void
    nonisolated(unsafe) static var waitPump: WaitPump?
    nonisolated(unsafe) static var waitPumpContext: UnsafeMutableRawPointer?

    /// Called while a command waits: puts up the sheet upstream asked for, if the shell can show it.
    @MainActor static func presentPendingSheet(for session: EditorSession) {
        guard !presenting, let sheetPresenter, session.showsRawDevelop else { return }
        presenting = true
        defer { presenting = false }
        sheetPresenter(sheetPresenterContext, "RawDevelopSheet")
    }

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
        // RAW: upstream's own Develop sheet (RawDevelopSheet), which the shell presents when `showsRawDevelop` turns on
        // while the import waits (UpstreamEditor.command). Without a presenter, develop as shot.
        if sheetPresenter == nil, session.confirmRawDevelop == nil {
            session.confirmRawDevelop = { _, asShot in asShot }
        }
    }
}

@_cdecl("compositor_set_conversion_prompt")
nonisolated public func compositorSetConversionPrompt(_ prompt: (@convention(c) (UnsafePointer<UInt8>?, Int) -> Int32)?) {
    ImportPrompts.conversionPrompt = prompt
}

@_cdecl("compositor_set_sheet_presenter")
nonisolated public func compositorSetSheetPresenter(_ presenter: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?,
                                                    _ context: UnsafeMutableRawPointer?) {
    ImportPrompts.sheetPresenter = presenter
    ImportPrompts.sheetPresenterContext = context
}

@_cdecl("compositor_set_wait_pump")
nonisolated public func compositorSetWaitPump(_ pump: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                              _ context: UnsafeMutableRawPointer?) {
    ImportPrompts.waitPump = pump
    ImportPrompts.waitPumpContext = context
}
