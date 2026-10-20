import AppKit
import CoreImage
import ImageIO
import Foundation
import Testing
@testable import Compositor
#if os(Linux)
import RenderParitySupport
#endif

/// Compiled verbatim on macOS and Linux. References are exports from the real upstream renderer.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_PARITY_OUTPUT"] != nil))
struct RenderParityTests {
    private let width = 96, height = 72
    private var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["COMPOSITOR_PARITY_OUTPUT"]!) }
    private var inputs: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["COMPOSITOR_PARITY_INPUT"]!) }

    private func image(overlay: Bool = false) throws -> CGImage {
        let c = try BrushRaster.context(width: width, height: height, mask: false)
        let p = try #require(c.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let i = y * c.bytesPerRow + x * 4
            let a = overlay ? (x < 12 || y < 12 || x > 80 || y > 58 ? 0 : 160) : 255
            p[i] = UInt8((x * 255 / (width - 1)) * a / 255)
            p[i + 1] = UInt8((y * 255 / (height - 1)) * a / 255)
            p[i + 2] = UInt8((overlay ? 220 : 100) * a / 255)
            p[i + 3] = UInt8(a)
        } }
        return try #require(c.makeImage())
    }

    private func snapshot(_ image: CGImage, foreground: CGImage? = nil, mode: LayerBlendMode = .normal,
                          opacity: Double = 1, adjustment: LayerAdjustment? = nil,
                          effects: LayerEffects? = nil, transform: LayerTransform? = nil) -> ProjectSnapshot {
        let base = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let top = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let t = LayerTransform(origin: .zero, size: CGSize(width: width, height: height))
        var records = [ProjectLayerRecord(id: base, name: "Base", isVisible: true, transform: t, imageFile: "\(base).png")]
        var images = [base: ImportedImage(image: image, thumbnail: image, name: "Base")]
        if let foreground {
            records.append(ProjectLayerRecord(id: top, name: "Top", isVisible: true, transform: transform ?? t,
                imageFile: "\(top).png", opacity: opacity, blendMode: mode, effects: effects))
            images[top] = ImportedImage(image: foreground, thumbnail: foreground, name: "Top")
        }
        if let adjustment {
            records.append(ProjectLayerRecord(id: top, name: "Adjustment", isVisible: true, transform: t,
                imageFile: nil, adjustment: adjustment))
        }
        return ProjectSnapshot(manifest: ProjectManifest(documentID: base, width: width, height: height,
            activeLayerID: records.last?.id, layers: records), images: images)
    }

    private func write(_ image: CGImage, category: String, name: String) throws {
        let folder = output.appendingPathComponent(category)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func rendered(_ snapshot: ProjectSnapshot, category: String, name: String) async throws {
        try write(try await ImageExporter.shared.render(snapshot).image, category: category, name: name)
    }

    @Test func exportCorpus() async throws {
#if os(Linux)
        try #require(compositor_parity_install() != 0, "The real Qt and LibRaw backends must be installed")
#endif
        let base = try image(), top = try image(overlay: true)
        for mode in LayerBlendMode.allCases {
            for opacity in [1.0, 0.5] {
                try await rendered(snapshot(base, foreground: top, mode: mode, opacity: opacity),
                    category: "blend", name: "\(mode.rawValue)-\(Int(opacity * 100))")
            }
        }
        for kind in AdjustmentKind.allCases {
            for amount in (kind == .invert ? [0.0] : [0.0, 35.0, -35.0]) {
                var adjustment = LayerAdjustment(kind: kind)
                adjustment.noiseSeed = 7
                adjustment.grain.seed = 7
                if amount != 0 {
                    switch kind {
                    case .hsv: adjustment.hue = amount; adjustment.saturation = amount
                    case .levels: adjustment.levels.current.gamma = amount > 0 ? 2 : 0.5
                    case .curves: adjustment.curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 128, y: 128 + amount * 2), CurvePoint(x: 255, y: 255)]
                    case .exposure: adjustment.exposure.exposure = amount / 17.5
                    case .gradientMap:
                        adjustment.gradientMap.shadows = AdjustmentColor(red: 0.3, green: 0.1, blue: 0.6)
                        adjustment.gradientMap.reversed = amount < 0
                    case .grain: adjustment.grain.amount = 70; adjustment.grain.size = amount > 0 ? 3 : 0.5
                    case .addNoise: adjustment.noiseAmount = 70; adjustment.noiseGaussian = amount < 0; adjustment.noiseMonochromatic = amount > 0
                    case .gaussianBlur: adjustment.gaussianRadius = amount > 0 ? 17 : 1
                    case .motionBlur: adjustment.resolvedMotionDistance = amount > 0 ? 35 : 2; adjustment.resolvedMotionAngle = amount
                    case .blackWhite: adjustment.blackWhite.reds = amount > 0 ? 200 : -100
                    case .colorBalance: adjustment.colorBalance.midCyanRed = amount * 2
                    case .invert: break
                    }
                }
                try await rendered(snapshot(base, adjustment: adjustment), category: "adjustment", name: "\(kind.rawValue)-\(Int(amount))")
            }
        }
        for kind in FilterKind.allCases where kind != .contentAwareFill && kind != .removeBackground {
            for extreme in [false, true] {
                var settings = FilterSettings()
                settings.grain.seed = 7
                if extreme {
                    settings.radius = 17; settings.distance = 35; settings.angle = 37
                    settings.progressiveTo = 55; settings.progressiveRadial = true
                    settings.amount = 70; settings.gaussian = true; settings.monochromatic = true
                    settings.vignetteAmount = 80; settings.vignetteRoundness = -50
                    settings.bloomAmount = 80; settings.bloomRadius = 40
                    settings.tonalAmount = 90; settings.distortion = 60
                    settings.curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 128, y: 200), CurvePoint(x: 255, y: 255)]
                    settings.exposure.exposure = 2
                    settings.gradientMap.reversed = true; settings.grain.amount = 70
                    settings.blackWhite.reds = 200; settings.colorBalance.midCyanRed = 70
                    settings.dither.pixelSize = 6; settings.scanlines.contrast = 60
                    settings.cameraRaw.exposure = 2; settings.cameraRaw.contrast = 60
                }
                var job = FilterJob(kind: kind, image: top, settings: settings, scale: 1, selection: nil, mapping: .identity)
                job.seed = 7
                job.canvas = CGRect(x: 0, y: 0, width: width, height: height)
                try write(PixelFilter.run(job), category: "filter", name: "\(kind.rawValue)-\(extreme ? "extreme" : "default")")
            }
        }
        var effects: [(String, LayerEffects)] = []
        effects.append(("stroke", LayerEffects(stroke: StrokeEffect())))
        effects.append(("shadow", LayerEffects(shadow: ShadowEffect())))
        effects.append(("overlay", LayerEffects(colorOverlay: ColorOverlayEffect())))
        effects.append(("inner-shadow", LayerEffects(innerShadow: InnerShadowEffect())))
        effects.append(("outer-glow", LayerEffects(outerGlow: OuterGlowEffect())))
        effects.append(("inner-glow", LayerEffects(innerGlow: InnerGlowEffect())))
        for (name, effect) in effects {
            try await rendered(snapshot(base, foreground: top, effects: effect), category: "effect", name: name)
        }
        for scale in [0.37, 1, 2.63] {
            for sampling in [LayerSampling.high, .nearest] {
                let t = LayerTransform(origin: CGPoint(x: 13, y: 7),
                    size: CGSize(width: Double(width) * scale, height: Double(height) * scale),
                    rotation: scale == 1 ? 17 : 0, sampling: sampling)
                try await rendered(snapshot(base, foreground: top, transform: t), category: "transform", name: "\(scale)-\(sampling)")
            }
        }
        var textImages: [Data] = []
        for face in ["Inter-Regular", "Inter-Bold", "Inter-Light"] {
            for size in [12.0, 24.0, 36.0] {
                let c = try BrushRaster.context(width: width, height: height, mask: false)
                let font = try #require(NSFont(name: face, size: size), "Install the exact bundled Inter fonts on both platforms")
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
                ("Ag Ω" as NSString).draw(at: CGPoint(x: 4, y: 20), withAttributes: [.font: font, .foregroundColor: NSColor.white])
                NSGraphicsContext.restoreGraphicsState()
                try write(try #require(c.makeImage()), category: "text", name: "\(face)-\(Int(size))")
                textImages.append(try Data(contentsOf: output.appendingPathComponent("text/\(face)-\(Int(size)).png")))
            }
        }
        #expect(Set(textImages).count == 9, "All font faces/sizes must render distinctly; a fallback is not parity evidence")
        for kind in ShapeKind.allCases {
            let c = try BrushRaster.context(width: width, height: height, mask: false)
            if kind == .line {
                c.move(to: CGPoint(x: 8, y: 8)); c.addLine(to: CGPoint(x: 72, y: 56))
            } else {
                c.addPath(kind.path(in: CGRect(x: 8, y: 8, width: 64, height: 48), cornerRadius: 12, smoothing: true))
            }
            c.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.5, alpha: 0.7))
            if kind == .line { c.setLineWidth(3); c.strokePath() } else { c.fillPath() }
            try write(try #require(c.makeImage()), category: "shape", name: kind.rawValue)
        }
        let profileData = try Data(contentsOf: inputs.appendingPathComponent("proof.icc"))
        let profile = try #require(CMYKProfile(name: "Parity SWOP", data: profileData))
        let inks = try CMYK.convert(base, to: profile, over: CGColor(gray: 1, alpha: 1))
        try write(inks, category: "color", name: "cmyk-roundtrip")
        // Profile conversion is tested with the same wide-gamut input bytes on both systems.
        for name in ["p3.png", "gray-alpha.png", "ramp16.tiff", "highlights.tiff"] {
            let imported = try await ImageImporter.shared.decode(inputs.appendingPathComponent(name))
            try write(imported.image, category: "color", name: name)
            if name == "ramp16.tiff" || name == "highlights.tiff" {
                let deep = try #require(imported.deep, "Deep color import must retain precision")
                let hdr = DeepLayer.isHDR(deep)
                let context = try hdr ? DeepLayer.hdr(deep) : DeepLayer.canonical(deep)
                let pointer = try #require(context.data).assumingMemoryBound(to: UInt16.self)
                var samples: [Double] = []
                for y in 0..<context.height { for x in 0..<(context.width * 4) {
                    let bits = pointer[y * context.bytesPerRow / 2 + x]
                    samples.append(hdr ? Double(Float16(bitPattern: bits)) : Double(bits) / 65535)
                } }
                let data = try JSONSerialization.data(withJSONObject: ["hdr": hdr, "width": context.width,
                    "height": context.height, "samples": samples])
                try data.write(to: output.appendingPathComponent("color/\(name).samples.json"))
            }
        }
        for index in 0..<5 {
            let raw = inputs.appendingPathComponent("sensor-\(index).dng")
            let settings = try #require(RawImporter.asShot(raw))
            let developed = try RawImporter.develop(raw, settings: settings, limit: nil)
            try write(developed, category: "raw", name: "sensor-\(index)")
        }
        try await rendered(snapshot(base, foreground: top), category: "export", name: "png")
    }
}
