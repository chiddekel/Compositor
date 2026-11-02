import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// Linux golden images (T-23 without a Mac): report 07's rendering cases — every blend mode at full and half opacity,
/// every adjustment, every filter at its defaults, every layer effect, transform sampling, text and shapes — rendered
/// through upstream's exporter and compared with baselines committed under Tests/Fixtures/golden-linux. They catch a
/// Linux rendering change (the compat layers, Skia, Vulkan, a backend fallback); they say nothing about how far
/// Linux is from macOS, which stays unverified until the same cases are rendered on a Mac.
///
/// COMPOSITOR_UPDATE_GOLDENS=1 rewrites the baselines (after a change meant to alter pixels; review the PNG diffs).
@MainActor
@Suite(.serialized)
struct LinuxGoldenImageTests {
    static let directory: URL = {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) {
            folder = folder.deletingLastPathComponent()
        }
        return folder.appendingPathComponent("Tests/Fixtures/golden-linux", isDirectory: true)
    }()
    private static let updating = ProcessInfo.processInfo.environment["COMPOSITOR_UPDATE_GOLDENS"] == "1"
    static let width = 64, height = 48

    // MARK: Scenes

    private func command(_ e: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async throws {
        var body = fields
        body["version"] = 1
        body["action"] = action
        let code = await e.commandAsync(try JSONSerialization.data(withJSONObject: body))
        try #require(code == 0, "\(action) failed: \(e.error ?? "code \(code)")")
    }

    /// A photo stand-in: smooth color ramps with a darker disc, fully opaque.
    static func photo() -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let dx = Double(x - 40) / 14, dy = Double(y - 22) / 12, inside = dx * dx + dy * dy < 1
            bytes[i] = UInt8(x * 255 / (width - 1)); bytes[i + 1] = UInt8(y * 255 / (height - 1))
            bytes[i + 2] = inside ? 40 : UInt8(255 - x * 3)
        } }
        return bytes
    }

    /// The layer blended over it: a horizontal gradient, its right third half transparent (premultiplied).
    static func overlay() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4, a = x > width * 2 / 3 ? 128 : 255
            bytes[i] = UInt8(a * (255 - x * 4) / 255); bytes[i + 1] = UInt8(a * (y * 5 % 256) / 255)
            bytes[i + 2] = UInt8(a * 200 / 255); bytes[i + 3] = UInt8(a)
        } }
        return bytes
    }

    private func editor(_ layers: [[UInt8]]) throws -> UpstreamEditor {
        let e = UpstreamEditor()
        for (index, pixels) in layers.enumerated() {
            try #require(e.importRGBA(pixels, width: Self.width, height: Self.height, name: "Layer \(index)", replacing: index == 0) == 0)
        }
        return e
    }

    private func render(_ e: UpstreamEditor) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(e.session.projectSnapshot())).image
    }

    static let blendCases: [String] = LayerBlendMode.allCases.flatMap { ["\($0.rawValue)@100", "\($0.rawValue)@50"] }

    private func blend(_ name: String) async throws -> CGImage {
        let parts = name.split(separator: "@")
        let e = try editor([Self.photo(), Self.overlay()])
        try await command(e, "setBlendMode", ["kind": String(parts[0])])
        if parts[1] == "50" { try await command(e, "setOpacity", ["value": 0.5]) }
        return try await render(e)
    }

    private func adjustment(_ kind: AdjustmentKind) async throws -> CGImage {
        let e = try editor([Self.photo()])
        try await command(e, "addAdjustment", ["kind": kind.rawValue])
        if e.session.adjustmentEditingID != nil { #expect(e.session.finishAdjustmentEditing(commit: true)) }
        return try await render(e)
    }

    private func filter(_ kind: FilterKind) throws -> CGImage {
        let image = CGImage(PortableImage(width: Self.width, height: Self.height, kind: .rgba, depth: .uint8,
                                          bytesPerRow: Self.width * 4, bytes: Self.overlay()))
        var job = FilterJob(kind: kind, image: image, settings: FilterSettings(), scale: 1, selection: nil, mapping: .identity)
        job.seed = 7
        job.canvas = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        return try PixelFilter.run(job)
    }

    private func effect(_ kind: LayerEffectKind) async throws -> CGImage {
        let e = try editor([Self.photo()])
        try await command(e, "addShape", ["kind": ShapeKind.allCases[1].rawValue, "x": 16.0, "y": 10.0, "width": 30.0, "height": 26.0,
                                          "parameters": ["red": 0.95, "green": 0.85, "blue": 0.2]])
        e.session.addEffect(kind)
        e.session.finishEffectsEditing(commit: true)
        return try await render(e)
    }

    static let transformCases = ["rotate 17° High", "scale 37% High", "scale 263% High", "scale 263% Nearest"]

    private func transform(_ name: String) async throws -> CGImage {
        let e = try editor([Self.photo(), Self.overlay()])
        let s = e.session
        s.beginTransform()
        var draft = try #require(s.transformEdit?.draft)
        let factor: CGFloat = name.contains("37%") ? 0.37 : name.contains("263%") ? 2.63 : 1
        draft.size = CGSize(width: draft.size.width * factor, height: draft.size.height * factor)
        draft.origin = CGPoint(x: CGFloat(Self.width) / 2 - draft.size.width / 2, y: CGFloat(Self.height) / 2 - draft.size.height / 2)
        if name.hasPrefix("rotate") { draft.rotation = 17 }
        draft.sampling = name.hasSuffix("Nearest") ? .nearest : .high
        s.previewTransform(draft)
        s.commitTransform()
        return try await render(e)
    }

    private func textAndShapes() async throws -> CGImage {
        let e = try editor([Self.photo()])
        try await command(e, "textBegin", ["x": 4.0, "y": 8.0])
        try await command(e, "textSetContent", ["name": "Ag"])
        try await command(e, "textFinish")
        for (index, kind) in ShapeKind.allCases.enumerated() {
            try await command(e, "addShape", ["kind": kind.rawValue, "x": 2.0 + Double(index * 10), "y": 32.0, "width": 9.0, "height": 12.0,
                                              "parameters": ["red": 0.1, "green": 0.3 + Double(index) / 10, "blue": 0.8]])
        }
        return try await render(e)
    }

    // MARK: Comparing

    /// An image as its PNG decodes: premultiplied RGBA8, what both the baseline and the new render go through.
    private func throughPNG(_ image: CGImage) throws -> (data: Data, pixels: [UInt8], width: Int, height: Int) {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let decoded = try decode(data as Data)
        return (data as Data, decoded.pixels, decoded.width, decoded.height)
    }

    private func decode(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (try UpstreamEditor.rgbaBytes(of: image).bytes, image.width, image.height)
    }

    /// Within one level a channel (rounding between backends: Vulkan where a device is used, the CPU path otherwise).
    private func matchesBaseline(_ image: CGImage, _ category: String, _ name: String) throws {
        let file = Self.directory.appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_") + ".png")
        let rendered = try throughPNG(image)
        if let directory = ProcessInfo.processInfo.environment["COMPOSITOR_GOLDEN_ARTIFACTS"] {
            let artifact = URL(fileURLWithPath: directory).appendingPathComponent(category, isDirectory: true)
                .appendingPathComponent(file.lastPathComponent)
            try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.data.write(to: artifact)
        }
        if Self.updating {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.data.write(to: file)
            return
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            Issue.record("No baseline for \(category)/\(name): capture with COMPOSITOR_GOLDEN_ARTIFACTS and review it")
            return
        }
        let baseline = try decode(try Data(contentsOf: file))
        try #require(baseline.width == rendered.width && baseline.height == rendered.height, "\(category)/\(name): size changed")
        var worst = 0, differing = 0
        for (a, b) in zip(baseline.pixels, rendered.pixels) {
            let delta = abs(Int(a) - Int(b))
            worst = max(worst, delta)
            if delta > 1 { differing += 1 }
        }
        #expect(worst <= 1, "\(category)/\(name): \(differing) channel values differ, by up to \(worst)")
    }

    // MARK: Tests

    @Test(arguments: blendCases)
    func blendModes(_ name: String) async throws { try matchesBaseline(try await blend(name), "blend", name) }

    @Test(arguments: AdjustmentKind.allCases)
    func adjustments(_ kind: AdjustmentKind) async throws {
        let image = try await adjustment(kind)
        // Noise and grain take their pattern from the layer (a new one each run). RGB Split's per-pixel sin hash
        // also varies with GPU transcendental precision. Compare their mean/spread here; the RGB Split tests
        // separately check spectral direction, streaks, radial center, alpha and ROI on both CPU and Vulkan.
        if kind == .addNoise || kind == .grain || kind == .rgbSplit { try matchesStatistics(image, "adjustment", kind.rawValue) }
        else { try matchesBaseline(image, "adjustment", kind.rawValue) }
    }

    private func statistics(_ pixels: [UInt8]) -> [(mean: Double, spread: Double)] {
        (0..<3).map { c in
            let values = stride(from: c, to: pixels.count, by: 4).map { Double(pixels[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return (mean, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot())
        }
    }

    private func matchesStatistics(_ image: CGImage, _ category: String, _ name: String) throws {
        let file = Self.directory.appendingPathComponent(category, isDirectory: true).appendingPathComponent(name.replacingOccurrences(of: " ", with: "_") + ".png")
        guard !Self.updating, FileManager.default.fileExists(atPath: file.path) else { try matchesBaseline(image, category, name); return }
        let baseline = statistics(try decode(try Data(contentsOf: file)).pixels), rendered = statistics(try throughPNG(image).pixels)
        for (c, (a, b)) in zip(baseline, rendered).enumerated() {
            #expect(abs(a.mean - b.mean) <= 2 && abs(a.spread - b.spread) <= max(1.5, a.spread * 0.1),
                    "\(category)/\(name) channel \(c): mean \(a.mean) -> \(b.mean), spread \(a.spread) -> \(b.spread)")
        }
    }

    /// Content-Aware Fill fills a selection from the pixels around it: with no selection there is nothing to render.
    @Test(arguments: FilterKind.allCases.filter { $0 != .contentAwareFill })
    func filters(_ kind: FilterKind) throws {
        let image = try filter(kind)
        if kind == .rgbSplit { try matchesStatistics(image, "filter", kind.rawValue) }
        else { try matchesBaseline(image, "filter", kind.rawValue) }
    }

    @Test(arguments: LayerEffectKind.allCases)
    func effects(_ kind: LayerEffectKind) async throws { try matchesBaseline(try await effect(kind), "effect", kind.rawValue) }

    @Test(arguments: transformCases)
    func transforms(_ name: String) async throws { try matchesBaseline(try await transform(name), "transform", name) }

    @Test func textAndShapeLayers() async throws { try matchesBaseline(try await textAndShapes(), "text", "text-and-shapes") }

    /// Export: a PNG of the flattened image decodes to it exactly; a JPEG at 0.9 stays within 40 dB of it.
    @Test func exportsDecodeToTheRender() async throws {
        let e = try editor([Self.photo(), Self.overlay()])
        try await command(e, "setBlendMode", ["kind": LayerBlendMode.allCases[3].rawValue])
        let image = try await render(e)
        let encoded = try throughPNG(image)
        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let reread = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let again = try throughPNG(reread)
        #expect(encoded.pixels == again.pixels, "a PNG re-encode changed pixels")
        // JPEG on photographic content (the smooth stand-in alone): the overlay's sawtooth is a worst case for any
        // encoder's halved chroma, which says nothing about export quality.
        let photo = try await render(try editor([Self.photo()]))
        let png = try throughPNG(photo)
        let jpegData = NSMutableData()
        let jpeg = try #require(CGImageDestinationCreateWithData(jpegData as CFMutableData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(jpeg, photo, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        try #require(CGImageDestinationFinalize(jpeg))
        let decoded = try decode(jpegData as Data)
        // Luma PSNR: JPEG keeps chroma at half resolution (as Apple's encoder does), so color edges always lose more.
        func luma(_ p: [UInt8], _ i: Int) -> Double { 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2]) }
        var squared = 0.0
        for index in 0..<(decoded.pixels.count / 4) {
            let delta = luma(decoded.pixels, index * 4) - luma(png.pixels, index * 4)
            squared += delta * delta
        }
        let psnr = 10 * log10(255 * 255 / max(1e-9, squared / Double(decoded.pixels.count / 4)))
        #expect(psnr >= 40, "JPEG 0.9 luma PSNR \(psnr) dB")
    }
}
