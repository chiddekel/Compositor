import Foundation
import AppKit
import UniformTypeIdentifiers

/// The questions upstream's importer asks through SwiftUI sheets, answered by the Qt shell instead.
///
/// With a sheet presenter registered by the shell, upstream's own sheets are shown — `RawDevelopSheet` for camera RAW,
/// `PSDConversionSheet` for Photoshop files — rendered from the session while the import waits (UpstreamEditor.command).
/// Without one, `EditorSession`'s test hooks answer instead (`confirmConversions` through the shell's plain prompt,
/// `confirmRawDevelop` with the camera's own settings).
enum ImportPrompts {
    /// The command's owner follows newly created artboard sessions across awaits without using global tab focus.
    @TaskLocal static var artboardOwner: UpstreamEditor?

    @MainActor static func attachArtboardSession(_ session: EditorSession) {
        guard let owner = artboardOwner else { return }
        owner.observeArtboardImport(session)
        install(on: session)
    }

    /// Shell callback: a JSON array of {"layer","message"} and its length; returns non-zero to go ahead.
    typealias ConversionPrompt = @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
    nonisolated(unsafe) static var conversionPrompt: ConversionPrompt?
    /// Shell callback that presents a SwiftUI sheet panel (e.g. "RawDevelopSheet") modally until upstream closes it.
    typealias SheetPresenter = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    nonisolated(unsafe) static var sheetPresenter: SheetPresenter?
    nonisolated(unsafe) static var sheetPresenterContext: UnsafeMutableRawPointer?
    typealias SessionSheetPresenter = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Void
    nonisolated(unsafe) static var sessionSheetPresenter: SessionSheetPresenter?
    nonisolated(unsafe) static var presenting = false
    /// Shell callback run while a long command (a RAW develop, a big Photoshop file) works off the main thread: repaints
    /// and shows progress, without taking input, so the window doesn't freeze.
    typealias WaitPump = @convention(c) (UnsafeMutableRawPointer?) -> Void
    nonisolated(unsafe) static var waitPump: WaitPump?
    nonisolated(unsafe) static var waitPumpContext: UnsafeMutableRawPointer?
    typealias SessionWaitPump = @convention(c) (UInt64) -> Void
    nonisolated(unsafe) static var sessionWaitPump: SessionWaitPump?

    @MainActor static func pump(for editor: UpstreamEditor) {
        if let sessionWaitPump, let handle = Sessions.entries.first(where: { $0.value.editor === editor })?.key {
            sessionWaitPump(handle)
        } else { waitPump?(waitPumpContext) }
    }

    /// Called while a command waits: puts up the sheet upstream asked for, if the shell can show it.
    @MainActor static func presentPendingSheet(for editor: UpstreamEditor) {
        guard !presenting, let panel = editor.openSheets.first else { return }
        guard sessionSheetPresenter != nil || sheetPresenter != nil else { return }
        presenting = true
        defer { presenting = false }
        if let sessionSheetPresenter, let handle = Sessions.entries.first(where: { $0.value.editor === editor })?.key {
            sessionSheetPresenter(handle, panel)
        } else if let sheetPresenter {
            sheetPresenter(sheetPresenterContext, panel)
        }
    }

    @MainActor static func install(on session: EditorSession) {
        // Photoshop: upstream's own conversion sheet (PSDConversionSheet) when the shell can present it — the session
        // then shows it while the file is read, as on the Mac. Only without a presenter, the shell's plain prompt.
        if sheetPresenter == nil, sessionSheetPresenter == nil, session.confirmConversions == nil {
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
        if sheetPresenter == nil, sessionSheetPresenter == nil, session.confirmRawDevelop == nil {
            session.confirmRawDevelop = { _, asShot in asShot }
        }
    }
}

@_cdecl("compositor_set_session_sheet_presenter")
nonisolated public func compositorSetSessionSheetPresenter(_ presenter: (@convention(c) (UInt64, UnsafePointer<CChar>?) -> Void)?) {
    ImportPrompts.sessionSheetPresenter = presenter
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

@_cdecl("compositor_set_session_wait_pump")
nonisolated public func compositorSetSessionWaitPump(_ pump: (@convention(c) (UInt64) -> Void)?) {
    ImportPrompts.sessionWaitPump = pump
}

/// Retries any pending preference writes. SQLite normally commits each UserDefaults change immediately;
/// the shell also asks periodically and on quit, so a temporary storage failure can recover.
@_cdecl("compositor_flush_preferences")
nonisolated public func compositorFlushPreferences() {
    UserDefaults.standard.synchronize()
}

/// The shell's file chooser for upstream's own `NSOpenPanel`s (View › CMYK › Load Profile and the Export As sheet's):
/// (title, message, extensions separated by commas, allows several, chooses folders, output, capacity) → the number of
/// paths chosen (0 when cancelled), written into `output` one a line; a negative count needs that capacity.
public typealias OpenPanelFunction = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
                                                    Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32

/// JSON panel options in, JSON array of absolute paths out. Negative byte count requests a larger buffer;
/// the host retains that selection for the retry instead of opening another chooser.
public typealias SessionFilePanelFunction = @convention(c) (UInt64, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?, Int) -> Int64

@MainActor private enum NativeFilePanelTypes {
    // macOS reads this app-defined package type's extension from Config/Info.plist.
    static let registered: Void = { UTType.register(.compositorProject, filenameExtension: "comp") }()
}

@_cdecl("compositor_set_session_file_panel")
nonisolated public func compositorSetSessionFilePanel(_ function: SessionFilePanelFunction?) {
    onMain {
        guard let function else { NSOpenPanel.openHandler = nil; NSSavePanel.handler = nil; return }
        _ = NativeFilePanelTypes.registered
        NSOpenPanel.openHandler = { presentNativeFilePanel($0, function: function) }
        NSSavePanel.handler = { presentNativeFilePanel($0, function: function) }
    }
}

@MainActor private func presentNativeFilePanel(_ panel: NSSavePanel, function: SessionFilePanelFunction) -> NSApplication.ModalResponse {
    guard let owner = nativePresentationOwner(panel.presentationWindow) else { return .cancel }
    let open = panel as? NSOpenPanel
    if let open, !open.canChooseFiles && !open.canChooseDirectories { return .cancel }
    let options: [String: Any] = [
        "save": open == nil, "title": panel.title, "message": panel.message, "name": panel.nameFieldStringValue,
        "extensions": panel.allowedContentTypes.flatMap { $0.tags[.filenameExtension] ?? [] },
        "multiple": open?.allowsMultipleSelection ?? false, "directories": open?.canChooseDirectories ?? false,
        "files": open?.canChooseFiles ?? true, "packagesAsDirectories": open?.treatsFilePackagesAsDirectories ?? false,
        "createDirectories": panel.canCreateDirectories, "extensionHidden": panel.isExtensionHidden
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: options), let descriptor = String(data: data, encoding: .utf8) else { return .cancel }
    var capacity = 64 * 1024
    while true {
        var output = [UInt8](repeating: 0, count: capacity)
        let size = descriptor.withCString { function(owner, $0, &output, capacity) }
        if size < 0 {
            guard size != Int64.min, -size <= 64 * 1024 * 1024, Int(-size) > capacity else { return .cancel }
            capacity = Int(-size)
            continue
        }
        guard nativePresentationOwner(panel.presentationWindow) == owner, size > 0, size <= capacity,
              let paths = try? JSONDecoder().decode([String].self, from: Data(output.prefix(Int(size)))),
              !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }) else { return .cancel }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if let open { open.urls = urls }
        panel.url = urls.first
        return .OK
    }
}

@_cdecl("compositor_set_open_panel")
nonisolated public func compositorSetOpenPanel(_ function: OpenPanelFunction?) {
    MainActor.assumeIsolated {
        guard let function else { NSOpenPanel.openHandler = nil; return }
        NSOpenPanel.openHandler = { panel in
            let extensions = panel.allowedContentTypes.flatMap { $0.tags[.filenameExtension] ?? [] }.joined(separator: ",")
            var capacity = 64 * 1024
            while true {
                var output = [CChar](repeating: 0, count: capacity)
                let count = panel.title.withCString { title in
                    panel.message.withCString { message in
                        extensions.withCString { types in
                            function(title, message, types, panel.allowsMultipleSelection ? 1 : 0,
                                     panel.canChooseDirectories ? 1 : 0, &output, capacity)
                        }
                    }
                }
                if count < 0 { capacity = Int(-count) + 1; continue }
                guard count > 0 else { return .cancel }
                panel.urls = String(cString: output).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                panel.url = panel.urls.first
                return panel.urls.isEmpty ? .cancel : .OK
            }
        }
    }
}
