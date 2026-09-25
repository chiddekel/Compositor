import Foundation

/// The questions upstream's importer asks through SwiftUI sheets, answered by the Qt shell instead.
///
/// With a sheet presenter registered by the shell, upstream's own sheets are shown — `RawDevelopSheet` for camera RAW,
/// `PSDConversionSheet` for Photoshop files — rendered from the session while the import waits (UpstreamEditor.command).
/// Without one, `EditorSession`'s test hooks answer instead (`confirmConversions` through the shell's plain prompt,
/// `confirmRawDevelop` with the camera's own settings).
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
    @MainActor static func presentPendingSheet(for editor: UpstreamEditor) {
        guard !presenting, let sheetPresenter, let panel = editor.openSheets.first else { return }
        presenting = true
        defer { presenting = false }
        sheetPresenter(sheetPresenterContext, panel)
    }

    @MainActor static func install(on session: EditorSession) {
        // Photoshop: upstream's own conversion sheet (PSDConversionSheet) when the shell can present it — the session
        // then shows it while the file is read, as on the Mac. Only without a presenter, the shell's plain prompt.
        if sheetPresenter == nil, session.confirmConversions == nil {
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

/// Writes upstream's preferences (UserDefaults: @AppStorage values, saved keyboard shortcuts, …) to disk. The Mac does
/// this by itself; Linux Foundation keeps them in memory until asked, so the shell asks periodically and on quit.
@_cdecl("compositor_flush_preferences")
nonisolated public func compositorFlushPreferences() {
    UserDefaults.standard.synchronize()
}
