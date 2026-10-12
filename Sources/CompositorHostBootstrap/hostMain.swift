// CompositorHostBootstrap — the Swift-side composition root for the Linux port.
//
// Why a Swift `@main`: on the Freedesktop Swift 6.3 SDK a non-Swift `main` cannot
// bootstrap the Swift runtime + Foundation (no `swift_initSwiftRuntime`; static
// embedding SEGVs at the first `Dictionary` allocation; shared embedding traps
// in Foundation `JSONDecoder`/`Data.withUnsafeBytes` even on pure-Swift `Data`).
// SwiftPM bootstraps both when the entry point is Swift, so the composition root
// is inverted: this Swift `@main` initializes the runtime and Foundation, then
// drives the host through a C ABI. In the Flatpak build, `main` here calls the
// Qt host's `compositor_host_run(argc, argv)` C entry (host/host_run.cpp) instead
// of the self-test below; the Qt host in turn calls back into `compositor_session_*`.
//
// This target's `main` runs the same create->new->paint->render->undo->redo->
// close journey through the real `compositor_session_*` C ABI that
// SessionJourneyTests verifies under `swift test`. It is the architectural proof
// that the Swift-`@main` root unblocks the host journey (Foundation works here,
// where it traps from a C++ main). Run: `swift run CompositorHostBootstrap`.

import Compositor
import AppKit
import CoreGraphics
import ImageIO
import Foundation
import FoundationCompat
import HostRun
import SwiftUI

@main
struct HostBootstrap {
    private struct HostingNativeProbe: @preconcurrency NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    static func main() {
        HostingMeasurementBackend.install(compositor_host_measure_swiftui)
        if CommandLine.arguments.contains("--text-backend-smoke") {
            let result = compositor_host_text_smoke(CommandLine.argc, CommandLine.unsafeArgv) {
                MainActor.assumeIsolated { HostBootstrap.runTextBackendProbe() }
            }
            guard result == 0 else { fail("Qt text backend smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--preferences-smoke") {
            runPreferencesSmoke()
            return
        }
        compositorConfigureBrushAcceleration(ProcessInfo.processInfo.environment["COMPOSITOR_BRUSH_BACKEND"] != "cpu")
        // The canvas draws with Core Graphics unless COMPOSITOR_FORCE_GPU_CANVAS=1: the GPU canvas frame runs through the
        // compat Core Image, on the CPU, many times slower. A user's own CompositorCPUCanvas setting still wins.
        if ProcessInfo.processInfo.environment["COMPOSITOR_FORCE_GPU_CANVAS"] != "1" {
            UserDefaults.standard.register(defaults: ["CompositorCPUCanvas": true])
        }
        if CommandLine.arguments.contains("--color-range-smoke") {
            let result = compositor_host_color_range_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt Color Range smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--interchange") {
            let result = compositor_host_interchange(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Interchange returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--raw-lens-smoke") {
            let result = compositor_host_raw_lens_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("RAW lens smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--preview-smoke") {
            let result = compositor_host_preview_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt preview smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--save-smoke") {
            let result = compositor_host_save_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt save smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--package-smoke") {
            let result = compositor_host_package_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt package smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--dialog-smoke") {
            let result = compositor_host_dialog_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt dialog smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--io-smoke") {
            let result = compositor_host_io_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt IO smoke returned \(result)") }
            // The same Qt plugins through Apple's CGImageSource/CGImageDestination API.
            guard ImageCodecRegistry.host != nil else { fail("Qt image backend was not registered") }
            var pixels = PixelBuffer(width: 8, height: 8)
            for y in 0..<8 { for x in 0..<8 { pixels[x, y] = (UInt8(x * 30), UInt8(y * 30), 120, 255) } }
            let jpegData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil) else { fail("no JPEG destination") }
            CGImageDestinationAddImage(destination, CGImage(pixels), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(jpegData as Data as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width == 8, decoded.height == 8 else {
                fail("JPEG did not round-trip through CGImageSource/CGImageDestination")
            }
            print("CompositorHostBootstrap: Qt IO smoke OK (ImageIO JPEG via Qt plugins)")
            return
        }
        if CommandLine.arguments.contains("--layers-smoke") {
            let result = compositor_host_layers_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt layers smoke returned \(result)") }
            print("CompositorHostBootstrap: Qt layers smoke OK")
            return
        }
        if CommandLine.arguments.contains("--brush-smoke") {
            let result = compositor_host_brush_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt brush smoke returned \(result)") }
            print("CompositorHostBootstrap: Qt brush smoke OK")
            return
        }
        if CommandLine.arguments.contains("--transform-smoke") {
            let result = compositor_host_transform_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt transform smoke returned \(result)") }
            print("CompositorHostBootstrap: Qt transform smoke OK")
            return
        }
        if CommandLine.arguments.contains("--combo-smoke") {
            let result = compositor_host_combo_smoke(CommandLine.argc, CommandLine.unsafeArgv)
            guard result == 0 else { fail("Qt tool combination smoke returned \(result)") }
            return
        }
        if CommandLine.arguments.contains("--session-smoke") {
            runSessionSmoke()
            print("CompositorHostBootstrap: session journey OK (create/new/paint/render/undo/redo/close)")
            return
        }

        // Run the Qt host window/event loop
        let qt = compositor_host_run(CommandLine.argc, CommandLine.unsafeArgv)
        guard qt == 0 else { fail("compositor_host_run returned \(qt)") }
    }

    @MainActor private static func runTextBackendProbe() -> Int32 {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "TextBackendSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        do {
            let label = NSHostingView(rootView: Text("Measured label"))
            let labelSize = label.fittingSize
            try check(label.intrinsicContentSize == labelSize, "default hosting options did not expose ideal metrics")
            label.sizingOptions = []
            try check(label.intrinsicContentSize == CGSize(width: -1, height: -1) && label.fittingSize == labelSize,
                      "empty hosting options changed explicit fitting bounds")
            label.sizingOptions = .intrinsicContentSize
            let autoLayoutParent = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
            label.translatesAutoresizingMaskIntoConstraints = false
            autoLayoutParent.addSubview(label)
            let hostingConstraints = [label.leadingAnchor.constraint(equalTo: autoLayoutParent.leadingAnchor),
                                      label.topAnchor.constraint(equalTo: autoLayoutParent.topAnchor)]
            NSLayoutConstraint.activate(hostingConstraints)
            defer { NSLayoutConstraint.deactivate(hostingConstraints) }
            autoLayoutParent.layoutSubtreeIfNeeded()
            try check(label.frame.size == labelSize, "Auto Layout did not consume renderer-backed intrinsic metrics")
            label.rootView = Text("A longer measured label")
            try check(autoLayoutParent.needsLayout, "text root update did not invalidate the parent layout")
            autoLayoutParent.layoutSubtreeIfNeeded()
            try check(label.frame.size == label.fittingSize && label.frame.width > labelSize.width,
                      "Auto Layout retained stale renderer-backed text bounds")
            label.rootView = Text("Measured label")
            let dimensionBounds = [label.widthAnchor.constraint(greaterThanOrEqualToConstant: labelSize.width + 20),
                                   label.widthAnchor.constraint(lessThanOrEqualToConstant: labelSize.width + 40)]
            NSLayoutConstraint.activate(dimensionBounds)
            autoLayoutParent.layoutSubtreeIfNeeded()
            let boundedSize = label.frame.size
            NSLayoutConstraint.deactivate(dimensionBounds)
            try check(boundedSize == CGSize(width: labelSize.width + 20, height: labelSize.height),
                      "required dimension bounds did not constrain renderer-backed hosting metrics")
            let limited = NSHostingView(rootView: Text("Hosting limits").frame(minWidth: 40, maxWidth: 180))
            limited.translatesAutoresizingMaskIntoConstraints = false
            autoLayoutParent.addSubview(limited)
            let limitedPlacement = [limited.leadingAnchor.constraint(equalTo: autoLayoutParent.leadingAnchor),
                                    limited.topAnchor.constraint(equalTo: autoLayoutParent.topAnchor)]
            NSLayoutConstraint.activate(limitedPlacement)
            defer { NSLayoutConstraint.deactivate(limitedPlacement + limited.constraints.filter {
                $0.identifier?.hasPrefix("compositor.hosting.") == true
            }) }
            autoLayoutParent.layoutSubtreeIfNeeded()
            try check(limited.constraints.first { $0.identifier == "compositor.hosting.min.width" }?.constant == 40
                      && limited.constraints.first { $0.identifier == "compositor.hosting.max.width" }?.constant == 180,
                      "hosting options did not generate renderer-backed limits")
            limited.rootView = Text("Updated hosting limits").frame(minWidth: 100, maxWidth: 220)
            autoLayoutParent.layoutSubtreeIfNeeded()
            try check(limited.constraints.first { $0.identifier == "compositor.hosting.min.width" }?.constant == 100
                      && limited.constraints.first { $0.identifier == "compositor.hosting.max.width" }?.constant == 220
                      && limited.frame.width >= 100 && limited.frame.width <= 220,
                      "hosting-generated limits did not follow a text root update")
            let windowContent = NSHostingView(rootView: Text("Window hosting")
                .frame(minWidth: 40, maxWidth: 180, minHeight: 24, maxHeight: 60))
            let contentWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                         styleMask: [], backing: .buffered, defer: false)
            contentWindow.contentView = windowContent
            try check(contentWindow.contentMinSize == CGSize(width: 40, height: 24)
                      && contentWindow.contentMaxSize == CGSize(width: 180, height: 60),
                      "window content bounds did not use renderer-backed metrics")
            contentWindow.setContentSize(CGSize(width: 400, height: 200))
            try check(contentWindow.frame.size == CGSize(width: 180, height: 60)
                      && windowContent.frame.size == contentWindow.frame.size,
                      "window content sizing ignored hosting bounds")
            windowContent.sizingOptions = []
            contentWindow.setContentSize(CGSize(width: 400, height: 200))
            try check(contentWindow.frame.size == CGSize(width: 400, height: 200),
                      "explicit window sizing stayed capped after clearing hosting options")
            contentWindow.contentView = nil
            try check(windowContent.window == nil, "replaced hosting root retained its window")
            try check(labelSize.width > 20 && labelSize.width < 300 && labelSize.height > 0 && labelSize.height < 40,
                      "hosting text retained placeholder bounds")
            let padded = NSHostingView(rootView: Text("Measured label").padding(12))
            try check(padded.fittingSize == CGSize(width: labelSize.width + 24, height: labelSize.height + 24),
                      "renderer measurement counted padding twice")
            let large = NSHostingView(rootView: Text("Measured label").font(.system(size: 28)))
            let inherited = NSHostingView(rootView: VStack(spacing: 0) { Text("Measured label") }.font(.system(size: 28)))
            try check(large.fittingSize.width > labelSize.width && large.fittingSize.height > labelSize.height,
                      "hosting measurement lost the font modifier")
            try check(inherited.fittingSize == large.fittingSize, "hosting measurement lost the inherited font")
            let wrapped = NSHostingView(rootView: Text("Measured label wraps across several lines")
                .multilineTextAlignment(.leading).frame(width: 80))
            try check(wrapped.fittingSize.width == 80 && wrapped.fittingSize.height > labelSize.height,
                      "hosting text ignored its constrained wrapping width")
            let oneLine = NSHostingView(rootView: Text("Measured label wraps across several lines")
                .multilineTextAlignment(.leading).lineLimit(1).frame(width: 80))
            try check(oneLine.fittingSize.height < wrapped.fittingSize.height, "hosting measurement ignored the line limit")
            var actions = 0
            let button = NSHostingView(rootView: Button("Measured label") { actions += 1 })
            try check(button.fittingSize.width > labelSize.width && button.fittingSize.height > labelSize.height,
                      "hosting button lost its control chrome")
            try check(actions == 0, "hosting measurement dispatched an action")
            let controls: [(String, AnyView)] = [
                ("toggle", AnyView(Toggle("Measured label", isOn: .constant(true)))),
                ("field", AnyView(TextField("Field", text: .constant("Value")))),
                ("slider", AnyView(Slider(value: .constant(0.5)))),
                ("picker", AnyView(Picker("Choice", selection: Binding.constant(0)) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                })),
                ("symbol", AnyView(Image(systemName: "checkmark")))
            ]
            for (name, view) in controls {
                let size = NSHostingView(rootView: view).fittingSize
                try check(size.width > 0 && size.height > 0 && size != CGSize(width: 320, height: 240),
                          "hosting \(name) retained placeholder bounds")
            }
            let unsupported = NSHostingView(rootView: Image("CompositorMissingImage").padding(12))
            try check(unsupported.fittingSize == CGSize(width: 320, height: 240),
                      "unsupported content collapsed to its padding")
            let row = NSHostingView(rootView: HStack(spacing: 8) {
                Text("Measured label")
                HostingNativeProbe().frame(width: 80, height: 20)
            })
            let rowSize = row.fittingSize
            row.frame = CGRect(origin: .zero, size: rowSize)
            try check(rowSize.width == labelSize.width + 88 && row.subviews.last?.frame.minX == labelSize.width + 8,
                      "native placement did not reserve the measured text width")
            HostingMeasurementBackend.install(nil)
            let unavailable = label.fittingSize
            HostingMeasurementBackend.install(compositor_host_measure_swiftui)
            try check(unavailable == CGSize(width: 320, height: 240), "headless hosting lost its unknown-size fallback")
            print("Qt hosting measurement smoke OK (text, generated/window limits, Auto Layout updates, inherited font, wrapping, controls, unknown fallback)")
            let names = NSFontManager.shared.availableFonts
            guard let sansName = ["DejaVu Sans", "Liberation Sans", "Noto Sans"].first(where: { names.contains($0) }),
                  let monoName = ["DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono"].first(where: { names.contains($0) }),
                  let sans = NSFont(name: sansName, size: 32), let mono = NSFont(name: monoName, size: 32) else {
                throw NSError(domain: "TextBackendSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Required installed sans/mono test fonts missing: \(names.prefix(20))"])
            }
            guard let postScriptFace = NSFont(name: "Inter-SemiBold", size: 32),
                  let fullNameFace = NSFont(name: "Inter SemiBold", size: 32) else {
                throw NSError(domain: "TextBackendSmoke", code: 7, userInfo: [NSLocalizedDescriptionKey: "Required named-font alias fixture missing"])
            }
            func namedText(_ font: NSFont) -> NSAttributedString {
                NSAttributedString(string: "iiii WWWW", attributes: [.font: font, .foregroundColor: NSColor.black])
            }
            guard let postScriptGlyphs = TextBackend.render(namedText(postScriptFace), maxWidth: 0, alignment: 0, boxWidth: 0),
                  let fullNameGlyphs = TextBackend.render(namedText(fullNameFace), maxWidth: 0, alignment: 0, boxWidth: 0),
                  let aliasBounds = TextBackend.layout(namedText(postScriptFace), maxWidth: 0),
                  let fullNameBounds = TextBackend.layout(namedText(fullNameFace), maxWidth: 0) else {
                throw NSError(domain: "TextBackendSmoke", code: 8)
            }
            try check(postScriptGlyphs.portableImage.bytes == fullNameGlyphs.portableImage.bytes
                      && postScriptGlyphs.width == fullNameGlyphs.width && postScriptGlyphs.height == fullNameGlyphs.height,
                      "PostScript/full names selected different glyph faces")
            try check(aliasBounds.width == fullNameBounds.width && aliasBounds.height == fullNameBounds.height,
                      "PostScript/full names measured different faces")
            print("Qt named-font glyph smoke OK (bundled Inter PostScript/full names select identical semibold pixels and bounds)")
            // The system factories carry their traits through the same attributed layout/render callbacks.
            func weightedText(_ weight: NSFont.Weight) -> NSAttributedString {
                NSAttributedString(string: "Weighted WWW iii", attributes: [.font: NSFont.systemFont(ofSize: 32, weight: weight),
                                                                            .foregroundColor: NSColor.black])
            }
            guard let regularGlyphs = TextBackend.render(weightedText(.regular), maxWidth: 0, alignment: 0, boxWidth: 0),
                  let semiboldGlyphs = TextBackend.render(weightedText(.semibold), maxWidth: 0, alignment: 0, boxWidth: 0),
                  let semiboldBounds = TextBackend.layout(weightedText(.semibold), maxWidth: 0) else {
                throw NSError(domain: "TextBackendSmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Native weighted glyph engine unavailable"])
            }
            try check(regularGlyphs.portableImage.bytes != semiboldGlyphs.portableImage.bytes, "system weight did not change glyph pixels")
            try check(semiboldGlyphs.width == Int(ceil(semiboldBounds.width)) && semiboldGlyphs.height == Int(ceil(semiboldBounds.height)),
                      "weighted measurement and glyph dimensions disagree")
            let nativeBounds = weightedText(.semibold).boundingRect(with: CGSize(width: 100_000, height: 100_000))
            try check(abs(nativeBounds.width - semiboldBounds.width) < 0.01, "weighted AppKit measurement bypassed native font traits")
            print("Qt system-font glyph smoke OK (regular/semibold pixels, attributed and AppKit bounds)")
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 44; paragraph.maximumLineHeight = 44
            let text = NSMutableAttributedString(string: "iiiiiiii WWWW\nA😀é", attributes: [.font: sans, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
            guard let plain = TextBackend.layout(text, maxWidth: 0) else { throw NSError(domain: "TextBackendSmoke", code: 3) }
            text.addAttribute(.font, value: mono, range: NSRange(location: 0, length: 8))
            text.addAttribute(.foregroundColor, value: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), range: NSRange(location: 6, length: 6))
            guard let measured = TextBackend.layout(text, maxWidth: 0),
                  let first = TextBackend.layout("iiiiiiii", font: mono, tracking: 0, lineHeight: 44, maxWidth: 0),
                  let last = TextBackend.layout(" WWWW", font: sans, tracking: 0, lineHeight: 44, maxWidth: 0),
                  let rendered = TextBackend.render(text, maxWidth: 0, alignment: 0, boxWidth: 0) else {
                throw NSError(domain: "TextBackendSmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Native attributed engine unavailable"])
            }
            try check(measured.width > plain.width + 20, "measurement ignored the per-letter face")
            try check(abs(measured.width - first.width - last.width) < 1, "mixed measurement differs from independent font advances")
            let bounds = text.boundingRect(with: CGSize(width: 100_000, height: 100_000))
            try check(abs(bounds.width - measured.width) < 0.01, "AppKit measurement bypassed font runs")
            try check(rendered.width == Int(ceil(measured.width)) && rendered.height == Int(ceil(measured.height)), "measure/render dimensions disagree")
            let bytes = rendered.portableImage.bytes
            var red = 0, dark = 0
            for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 230 {
                if bytes[index] > 200 && bytes[index + 1] < 30 { red += 1 }
                if bytes[index] < 30 && bytes[index + 1] < 30 { dark += 1 }
            }
            try check(red > 20 && dark > 20, "overlapping color and font ranges were not both rendered")
            guard let wrapped = TextBackend.layout(text, maxWidth: 120),
                  let wrappedImage = TextBackend.render(text, maxWidth: 120, alignment: 1, boxWidth: 120) else {
                throw NSError(domain: "TextBackendSmoke", code: 5)
            }
            try check(wrapped.height > measured.height && wrappedImage.height == Int(ceil(wrapped.height)), "mixed-font wrapping differs between measurement and drawing")
            let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                bytesPerRow: rendered.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Match BrushRaster.context: text layers draw in a top-left coordinate space.
            context.translateBy(x: 0, y: CGFloat(rendered.height)); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.current = nil }
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 100_000, height: 100_000))
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
            let drawn = context.makeImage()!.portableImage.bytes
            try check(drawn == bytes, "AppKit glyph rendering differs from the attributed backend")
            try check(NSFont(name: "CompositorMissingFace-DoesNotExist", size: 32) == nil, "missing face did not request explicit system fallback")
            print("Qt text backend journey OK (\(sansName) + \(monoName); mixed measurement, drawing, wrapping, UTF-16 colors, fallback)")
            return 0
        } catch {
            print("Qt text backend journey failed: \(error)")
            return 1
        }
    }

    private static func runPreferencesSmoke() {
        let workerDirectory = ProcessInfo.processInfo.environment["COMPOSITOR_PREFERENCES_SMOKE_ROOT"]
        let directory = workerDirectory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("compositor-preferences-\(UUID())")
        defer { if workerDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Exercise read-only migration from a real Foundation plist without ever writing through Foundation.
            let legacy = directory.appendingPathComponent("\(ProcessInfo.processInfo.processName).plist")
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>layersPanelWidth</key><real>321.5</real>
            <key>NSRecentDocumentURLs</key><array><string>/tmp/legacy.comp</string></array>
            </dict></plist>
            """
            if workerDirectory == nil {
                try Data(plist.utf8).write(to: legacy)
                // Foundation caches its configuration directory before main; set the environment before launch.
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
                child.arguments = ["--preferences-smoke"]
                var environment = ProcessInfo.processInfo.environment
                environment["XDG_CONFIG_HOME"] = directory.path
                environment["COMPOSITOR_PREFERENCES_SMOKE_ROOT"] = directory.path
                child.environment = environment
                try child.run()
                child.waitUntilExit()
                guard child.terminationStatus == 0 else { fail("preferences smoke child failed") }
                return
            }
            let defaults = SQLiteUserDefaults.standard
            guard defaults.double(forKey: "layersPanelWidth") == 321.5,
                  defaults.stringArray(forKey: "NSRecentDocumentURLs") == ["/tmp/legacy.comp"] else {
                fail("legacy preference migration")
            }
            // This is the exact save/autosave entry point that trapped in static Foundation's array writer.
            "/tmp/preferences-smoke.comp".withCString { compositorNoteRecentProject($0) }
            compositorFlushPreferences()
            guard defaults.stringArray(forKey: "NSRecentDocumentURLs")?.first == "/tmp/preferences-smoke.comp",
                  defaults.synchronize() else { fail("recent project preference write") }
            let reopened = SQLiteUserDefaults(databaseURL: directory.appendingPathComponent("Compositor/preferences.sqlite3"))
            guard reopened.stringArray(forKey: "NSRecentDocumentURLs")?.first == "/tmp/preferences-smoke.comp",
                  reopened.double(forKey: "layersPanelWidth") == 321.5,
                  try Data(contentsOf: legacy) == Data(plist.utf8) else { fail("preference persistence") }
            print("CompositorHostBootstrap: preferences OK (legacy import / save-autosave recents / SQLite reopen)")
        } catch { fail("preferences smoke: \(error)") }
    }

    private static func runSessionSmoke() {
        let h = compositorSessionCreate()
        guard h != 0 else { fail("session create returned 0") }

        func cmd(_ json: String) -> Int32 {
            let bytes = Array(json.utf8)
            return bytes.withUnsafeBufferPointer { buf in
                compositorSessionCommand(h, buf.baseAddress, buf.count)
            }
        }

        guard cmd(#"{"version":1,"action":"new","width":4,"height":4}"#) == 0 else { fail("new canvas") }
        guard cmd(#"{"version":1,"action":"addLayer"}"#) == 0 else { fail("add layer") }
        guard cmd(#"{"version":1,"action":"brushBegin","x":1,"y":1,"parameters":{"diameter":3,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}}"#) == 0 else { fail("brush begin") }
        guard cmd(#"{"version":1,"action":"brushMove","x":2,"y":2}"#) == 0 else { fail("brush move") }
        guard cmd(#"{"version":1,"action":"brushEnd"}"#) == 0 else { fail("brush end") }

        let stateN = compositorSessionState(h, nil, 0)
        guard stateN > 0 else { fail("state byte count") }
        var stateBytes = [UInt8](repeating: 0, count: Int(stateN))
        _ = stateBytes.withUnsafeMutableBufferPointer { buf in
            compositorSessionState(h, buf.baseAddress, Int(stateN))
        }
        let stateJSON = String(bytes: stateBytes, encoding: .utf8) ?? ""
        guard stateJSON.contains(#""width":4"#) else { fail("state width, got: \(stateJSON)") }
        guard stateJSON.contains(#""canUndo":true"#) else { fail("state canUndo, got: \(stateJSON)") }

        var pixels = [UInt8](repeating: 0, count: 64)
        let n = pixels.withUnsafeMutableBufferPointer { buf in
            compositorSessionRender(h, buf.baseAddress, 64)
        }
        guard n == 64 else { fail("render byte count \(n)") }
        var hasRed = false
        for i in stride(from: 0, to: 64, by: 4) {
            if pixels[i] > 0 && pixels[i + 1] == 0 && pixels[i + 2] == 0 && pixels[i + 3] > 0 { hasRed = true; break }
        }
        guard hasRed else { fail("render shows red paint after stroke") }

        guard cmd(#"{"version":1,"action":"undo"}"#) == 0 else { fail("undo") }
        _ = pixels.withUnsafeMutableBufferPointer { buf in compositorSessionRender(h, buf.baseAddress, 64) }
        var blank = true
        for i in stride(from: 0, to: 64, by: 4) {
            if pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0 || pixels[i + 3] != 0 { blank = false; break }
        }
        guard blank else { fail("render blank after undo") }
        guard cmd(#"{"version":1,"action":"redo"}"#) == 0 else { fail("redo") }
        _ = pixels.withUnsafeMutableBufferPointer { buf in compositorSessionRender(h, buf.baseAddress, 64) }
        var red2 = false
        for i in stride(from: 0, to: 64, by: 4) {
            if pixels[i] > 0 && pixels[i + 1] == 0 && pixels[i + 2] == 0 && pixels[i + 3] > 0 { red2 = true; break }
        }
        guard red2 else { fail("render red after redo") }

        compositorSessionClose(h)
        guard cmd(#"{"version":1,"action":"undo"}"#) == -6 else { fail("closed handle rejected") }
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write("CompositorHostBootstrap FAIL: \(msg)\n".data(using: .utf8)!)
        exit(1)
    }
}
