// Native Core Graphics samples for investigating high-quality image downsampling.
// The context and draw recipe match BrushRaster.context and DitherSettings.apply.
#if os(macOS)
import Foundation
import CoreGraphics
import CryptoKit
import Accelerate
import AppKit
import CoreText

enum CaptureError: Error { case failed(String) }

func bitmap(width: Int, height: Int, floating: Bool = false) throws -> CGContext {
    let components = floating ? CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                              : CGBitmapInfo.byteOrder32Big.rawValue
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: floating ? 32 : 8,
        bytesPerRow: width * (floating ? 16 : 4),
        space: CGColorSpace(name: floating ? CGColorSpace.extendedSRGB : CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | components) else {
        throw CaptureError.failed("Cannot allocate native bitmap")
    }
    result.translateBy(x: 0, y: CGFloat(height))
    result.scaleBy(x: 1, y: -1)
    return result
}

func bytes(_ context: CGContext) throws -> Data {
    guard let data = context.data else { throw CaptureError.failed("Missing bitmap data") }
    var result = Data()
    let packedRowBytes = context.width * context.bitsPerPixel / 8
    for y in 0..<context.height {
        result.append(data.advanced(by: y * context.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                      count: packedRowBytes)
    }
    return result
}

func describe(_ context: CGContext) throws -> [String: Any] {
    let data = try bytes(context)
    return ["width": context.width, "height": context.height, "rowBytes": context.width * context.bitsPerPixel / 8,
            "bitsPerComponent": context.bitsPerComponent,
            "rgbaBase64": data.base64EncodedString(),
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
}

func sampleCoreGraphics(_ image: CGImage, block: Int, floating: Bool = false) throws -> CGContext {
    let small = try bitmap(width: (image.width + block - 1) / block,
                           height: (image.height + block - 1) / block, floating: floating)
    small.saveGState()
    small.interpolationQuality = .high
    small.translateBy(x: 0, y: CGFloat(image.height) / CGFloat(block))
    small.scaleBy(x: 1, y: -1)
    small.setBlendMode(.copy)
    small.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) / CGFloat(block),
                                 height: CGFloat(image.height) / CGFloat(block)))
    small.restoreGState()
    return small
}

func captureAffine(_ source: CGContext, width: Int, height: Int, scaleX: Double, scaleY: Double,
                   translationX: Double, translationY: Double, flags: vImage_Flags) throws -> [String: Any] {
    let warped = try bitmap(width: width, height: height)
    var input = vImage_Buffer(data: source.data, height: vImagePixelCount(source.height),
        width: vImagePixelCount(source.width), rowBytes: source.bytesPerRow)
    var output = vImage_Buffer(data: warped.data, height: vImagePixelCount(height),
        width: vImagePixelCount(width), rowBytes: warped.bytesPerRow)
    var transform = vImage_AffineTransform_Double(a: scaleX, b: 0, c: 0, d: scaleY,
                                               tx: translationX, ty: translationY)
    let background: [UInt8] = [0, 0, 0, 0]
    let error = background.withUnsafeBufferPointer { color in
        vImageAffineWarpD_ARGB8888(&input, &output, nil, &transform, color.baseAddress, flags)
    }
    guard error == kvImageNoError else { throw CaptureError.failed("vImage affine warp failed: \(error)") }
    return ["scaleX": scaleX, "scaleY": scaleY, "translationX": translationX,
            "translationY": translationY, "output": try describe(warped)]
}

// Separate native glyph placement from smoothing and baseline rasterization.
func captureTextParagraphGeometry() throws -> [[String: Any]] {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("third_party/fonts/inter/Inter-Regular.ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    let recipes: [(String, String, Double, Double, Double, Double, Int)] = [
        ("tight-leading", "Ag Ω", 12.5, 10, 0, 1e7, 0),
        ("loose-leading", "Ag Ω", 12.5, 19.25, 0, 1e7, 0),
        ("wrapped", "Ag Ω", 12.5, 0, 0, 18, 0),
        ("tracking", "Ag Ω", 12.5, 0, 1.25, 1e7, 0),
        ("centered", "Ag Ω", 12.5, 0, 0, 80, 1),
        ("right-aligned", "Ag Ω", 12.5, 0, 0, 80, 2),
        ("multiline", "Ag Ω\nAg Ω", 12.5, 0, 0, 1e7, 0),
        ("combining", "Ag\u{0301} Ω", 12.5, 0, 0, 1e7, 0),
        ("ligature", "office", 24, 0, 0, 1e7, 0),
        ("surrogate", "A😀\nΩ", 12.5, 0, 0, 1e7, 0),
        ("bidi-controls", "A\u{202E}BC\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-left-override", "A\u{202D}BC\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-right-embedding", "A\u{202B}BC\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-left-embedding", "A\u{202A}BC\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-right-isolate", "A\u{2067}BC\u{2069} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-left-isolate", "A\u{2066}BC\u{2069} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-unmatched", "A\u{202E}BC Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-nested", "A\u{202E}B\u{202D}CD\u{202C}E\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-tracking", "A\u{202E}BC\u{202C} Ω", 12.5, 0, 1.25, 1e7, 0),
        ("bidi-size24", "A\u{202E}BC\u{202C} Ω", 24, 0, 0, 1e7, 0),
        ("bidi-only", "\u{202E}\u{202C}", 12.5, 0, 0, 1e7, 0),
        ("bidi-initial", "\u{202E}Ag Ω\u{202C}", 12.5, 0, 0, 1e7, 0),
        ("bidi-adjacent", "A\u{202E}BC\u{202C} D\u{202E}EF\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-first-strong", "A\u{2068}BC\u{2069} Ω", 12.5, 0, 0, 1e7, 0)]
    var cases = [[String: Any]]()
    for (name, content, size, height, tracking, width, alignment) in recipes {
        guard let font = NSFont(name: "Inter-Regular", size: size) else {
            throw CaptureError.failed("Cannot resolve paragraph geometry font")
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.alignment = alignment == 1 ? .center : alignment == 2 ? .right : .left
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: content, attributes: [.font: font, .kern: tracking, .paragraphStyle: paragraph])
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: 1e7))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let range = manager.glyphRange(for: container)
        var glyphs = [[String: Any]]()
        for index in range.location..<(range.location + range.length) {
            let location = manager.location(forGlyphAt: index)
            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            let fragment = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effectiveRange)
            glyphs.append(["glyph": Int(manager.glyph(at: index)), "characterIndex": manager.characterIndexForGlyph(at: index),
                           "location": [Double(location.x), Double(location.y)],
                           "lineFragment": [Double(fragment.minX), Double(fragment.minY), Double(fragment.width), Double(fragment.height)],
                           "effectiveRange": [effectiveRange.location, effectiveRange.length]])
        }
        cases.append(["name": name, "text": content, "face": font.fontName, "size": size,
                      "lineHeight": height, "tracking": tracking, "width": width, "alignment": alignment,
                      "utf16Length": text.length, "controlGlyph": Int(NSControlGlyph), "glyphs": glyphs])
    }
    return cases
}

func captureTextFallbackFonts() throws -> [[String: Any]] {
    guard let primary = NSFont(name: "Inter-Regular", size: 12.5) else {
        throw CaptureError.failed("Cannot resolve fallback-control primary font")
    }
    func describeFont(_ font: CTFont) -> [String: Any] {
        let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
        return ["name": CTFontCopyPostScriptName(font) as String, "family": CTFontCopyFamilyName(font) as String,
                "size": Double(CTFontGetSize(font)), "ascent": Double(CTFontGetAscent(font)),
                "descent": Double(CTFontGetDescent(font)), "leading": Double(CTFontGetLeading(font)),
                "file": url?.lastPathComponent ?? "unknown"]
    }
    var cases = [[String: Any]]()
    for (name, content) in [("plain", "Ag Ω"), ("surrogate", "A😀\nΩ"),
                             ("bidi-controls", "A\u{202E}BC\u{202C} Ω")] {
        let text = NSAttributedString(string: content, attributes: [.font: primary, .kern: 0])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        var runs = [[String: Any]]()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let range = CTRunGetStringRange(run)
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            runs.append(["font": describeFont(font), "range": [range.location, range.length],
                         "glyphs": glyphs.map { Int($0) },
                         "advances": advances.map { [Double($0.width), Double($0.height)] }])
        }
        cases.append(["name": name, "text": content, "primary": describeFont(primary as CTFont), "runs": runs])
    }
    return cases
}

func captureTextGeometry() throws -> [[String: Any]] {
    let fonts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("third_party/fonts/inter")
    let faces = ["Inter-Regular", "Inter-Bold", "Inter-Light"]
    for face in faces {
        CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent("\(face).ttf") as CFURL, .process, nil)
    }
    func rect(_ value: CGRect) -> [Double] {
        [Double(value.origin.x), Double(value.origin.y), Double(value.width), Double(value.height)]
    }
    var cases = [[String: Any]]()
    for face in faces {
        for size in [12.0, 24.0, 36.0, 12.5, 24.5, 36.5] {
            guard let font = NSFont(name: face, size: size) else {
                throw CaptureError.failed("Cannot resolve geometry font: \(face)")
            }
            let text = NSAttributedString(string: "Ag Ω", attributes: [.font: font, .foregroundColor: NSColor.white])
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: 1e7, height: 1e7))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let range = manager.glyphRange(for: container)
            var glyphs = [[String: Any]]()
            for index in range.location..<(range.location + range.length) {
                guard let converted = CGGlyph(exactly: manager.glyph(at: index)) else {
                    throw CaptureError.failed("Text geometry glyph is outside the Core Text range")
                }
                var glyph = converted
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
                let bounds = CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyph, nil, 1)
                let location = manager.location(forGlyphAt: index)
                glyphs.append(["glyph": Int(glyph), "characterIndex": manager.characterIndexForGlyph(at: index),
                               "location": [Double(location.x), Double(location.y)],
                               "advance": [Double(advance.width), Double(advance.height)], "bounds": rect(bounds),
                               "lineFragment": rect(manager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil))])
            }
            let line = CTLineCreateWithAttributedString(text as CFAttributedString)
            var ascent = CGFloat.zero, descent = CGFloat.zero, leading = CGFloat.zero
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            var coreTextRuns = [[String: Any]]()
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var ids = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                coreTextRuns.append(["glyphs": ids.map { Int($0) },
                                     "positions": positions.map { [Double($0.x), Double($0.y)] },
                                     "advances": advances.map { [Double($0.width), Double($0.height)] }])
            }
            let lineHeight = manager.defaultLineHeight(for: font)
            let baselines = [("rounded-ascent", lineHeight - ceil(font.ascender)),
                             ("fractional-ascent", lineHeight - font.ascender),
                             ("descent", -font.descender)]
            var draws = [[String: Any]]()
            for smoothing in [true, false] {
                let layoutContext = try bitmap(width: 96, height: 144)
                layoutContext.setAllowsFontSmoothing(smoothing)
                layoutContext.setShouldSmoothFonts(smoothing)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: layoutContext, flipped: false)
                manager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 4, y: 20))
                NSGraphicsContext.restoreGraphicsState()
                draws.append(["engine": "NSLayoutManager", "smoothing": smoothing, "output": try describe(layoutContext)])
                for (name, baseline) in baselines {
                    let context = try bitmap(width: 96, height: 144)
                    context.setAllowsFontSmoothing(smoothing)
                    context.setShouldSmoothFonts(smoothing)
                    context.textPosition = CGPoint(x: 4, y: 20 + baseline)
                    CTLineDraw(line, context)
                    draws.append(["engine": "CTLine", "baselinePolicy": name, "baselineOffset": Double(baseline),
                                  "smoothing": smoothing, "output": try describe(context)])
                }
            }
            cases.append(["face": face, "size": size, "glyphs": glyphs, "usedRect": rect(manager.usedRect(for: container)),
                          "lineHeight": Double(lineHeight), "coreTextRuns": coreTextRuns,
                          "coreTextMetrics": ["width": width, "ascent": Double(ascent),
                                              "descent": Double(descent), "leading": Double(leading)], "draws": draws])
        }
    }
    return cases
}

// Resolve the actual face as well as its pixels: matching a PostScript name alone
// does not prove that the macOS and Linux renderers selected the same font file.
func captureText() throws -> [[String: Any]] {
    let fonts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("third_party/fonts/inter")
    let faces = ["Inter-Regular", "Inter-Bold", "Inter-Light"]
    for face in faces {
        let url = fonts.appendingPathComponent("\(face).ttf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureError.failed("Missing bundled font: \(face)")
        }
        // A duplicate registration is harmless; the resolved file is recorded below.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    var cases = [[String: Any]]()
    for face in faces {
        let bundledData = try Data(contentsOf: fonts.appendingPathComponent("\(face).ttf"))
        let bundledHash = SHA256.hash(data: bundledData).map { String(format: "%02x", $0) }.joined()
        for size in [12.0, 24.0, 36.0, 12.5, 24.5, 36.5] {
            guard let font = NSFont(name: face, size: size),
                  let resolvedURL = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL else {
                throw CaptureError.failed("Cannot resolve native font: \(face)")
            }
            let resolvedData = try Data(contentsOf: resolvedURL)
            let resolvedHash = SHA256.hash(data: resolvedData).map { String(format: "%02x", $0) }.joined()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let measured = ("Ag Ω" as NSString).size(withAttributes: attributes)
            var draws = [[String: Any]]()
            for variant in ["default", "no-smoothing", "no-antialias", "white-on-black", "black-on-white"] {
                let context = try bitmap(width: 96, height: 72)
                if variant == "white-on-black" || variant == "black-on-white" {
                    context.setFillColor(gray: variant == "black-on-white" ? 1 : 0, alpha: 1)
                    context.fill(CGRect(x: 0, y: 0, width: 96, height: 72))
                }
                if variant == "no-smoothing" {
                    context.setAllowsFontSmoothing(false)
                    context.setShouldSmoothFonts(false)
                }
                if variant == "no-antialias" { context.setShouldAntialias(false) }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                ("Ag Ω" as NSString).draw(at: CGPoint(x: 4, y: 20), withAttributes: [
                    .font: font, .foregroundColor: variant == "black-on-white" ? NSColor.black : NSColor.white])
                NSGraphicsContext.restoreGraphicsState()
                draws.append(["variant": variant, "output": try describe(context)])
            }
            cases.append(["face": face, "size": size, "resolvedName": font.fontName,
                          "bundledSha256": bundledHash, "resolvedSha256": resolvedHash,
                          "matchesBundledFont": bundledHash == resolvedHash,
                          "resolvedFile": resolvedURL.lastPathComponent,
                          "ascender": font.ascender, "descender": font.descender,
                          "leading": font.leading, "capHeight": font.capHeight, "xHeight": font.xHeight,
                          "defaultLineHeight": NSLayoutManager().defaultLineHeight(for: font),
                          "measuredWidth": measured.width, "measuredHeight": measured.height,
                          "draws": draws])
        }
    }
    return cases
}

func captureBlend(_ mode: CGBlendMode) throws -> [String: Any] {
    let side = 256
    let source = try bitmap(width: side, height: side)
    guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
        throw CaptureError.failed("Missing source-over pixels")
    }
    for alpha in 0..<side { for value in 0..<side {
        let at = alpha * source.bytesPerRow + value * 4
        pixels[at] = UInt8(32 * alpha / 255)
        pixels[at + 1] = UInt8(43 * alpha / 255)
        pixels[at + 2] = UInt8(220 * alpha / 255)
        pixels[at + 3] = UInt8(alpha)
    } }
    guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make source-over image") }
    var cases = [[String: Any]]()
    for background in ["opaque", "translucent", "clear"] {
        for opacity in [1.0, 0.5, 0.25] {
            let target = try bitmap(width: side, height: side)
            guard let pixels = target.data?.assumingMemoryBound(to: UInt8.self) else {
                throw CaptureError.failed("Missing source-over destination")
            }
            for alpha in 0..<side { for value in 0..<side {
                let at = alpha * target.bytesPerRow + value * 4
                let a = background == "opaque" ? 255 : background == "clear" ? 0 : value
                pixels[at] = UInt8(value * a / 255)
                pixels[at + 1] = UInt8((255 - value) * a / 255)
                pixels[at + 2] = UInt8(100 * a / 255)
                pixels[at + 3] = UInt8(a)
            } }
            let initial = try describe(target)
            target.interpolationQuality = .none
            target.translateBy(x: 0, y: CGFloat(side))
            target.scaleBy(x: 1, y: -1)
            target.setAlpha(opacity)
            target.setBlendMode(mode)
            target.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            cases.append(["background": background, "opacity": opacity, "input": initial,
                          "output": try describe(target)])
        }
    }
    return ["source": try describe(source), "cases": cases]
}

func captureNonseparablePairs() throws -> [String: Any] {
    // Isolate rounding when opacity collapses the source hue or the backdrop's
    // saturation. These pairs include the application corpus's remaining edge cases.
    let pairs: [(String, [UInt8], [UInt8])] = [
        ("source-nearly-gray", [199, 200, 200, 255], [56, 217, 213, 255]),
        ("clipped-saturation", [20, 31, 138, 160], [32, 50, 100, 255]),
        ("clipped-saturation-second", [23, 40, 138, 160], [37, 64, 100, 255]),
        ("backdrop-nearly-gray", [62, 62, 138, 160], [99, 100, 100, 255]),
        ("backdrop-small-range", [62, 65, 138, 160], [99, 104, 100, 255]),
        ("gray-translucent", [100, 100, 100, 255], [100, 10, 50, 128]),
        ("clear-source", [0, 0, 0, 0], [10, 20, 30, 128]),
        ("clear-backdrop", [1, 1, 1, 1], [0, 0, 0, 0])]
    let source = try bitmap(width: pairs.count, height: 1)
    guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
        throw CaptureError.failed("Missing nonseparable source pixels")
    }
    for (index, pair) in pairs.enumerated() {
        for channel in 0..<4 { pixels[index * 4 + channel] = pair.1[channel] }
    }
    guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make nonseparable source image") }
    var cases = [[String: Any]]()
    for (name, mode) in [("hue", CGBlendMode.hue), ("saturation", CGBlendMode.saturation)] {
        for opacity in [1.0, 0.5, 0.25] {
            let target = try bitmap(width: pairs.count, height: 1)
            guard let pixels = target.data?.assumingMemoryBound(to: UInt8.self) else {
                throw CaptureError.failed("Missing nonseparable backdrop pixels")
            }
            for (index, pair) in pairs.enumerated() {
                for channel in 0..<4 { pixels[index * 4 + channel] = pair.2[channel] }
            }
            let initial = try describe(target)
            target.interpolationQuality = .none
            target.translateBy(x: 0, y: 1)
            target.scaleBy(x: 1, y: -1)
            target.setAlpha(opacity)
            target.setBlendMode(mode)
            target.draw(image, in: CGRect(x: 0, y: 0, width: pairs.count, height: 1))
            cases.append(["mode": name, "opacity": opacity, "input": initial, "output": try describe(target)])
        }
    }
    return ["labels": pairs.map { $0.0 }, "source": try describe(source), "cases": cases]
}

func capture() throws -> [String: Any] {
    let width = 96, height = 72
    var cases = [[String: Any]]()
    for fixture in ["overlay", "impulse-48", "impulse-49", "impulse-50", "impulse-51",
                    "vertical-48", "vertical-49", "constant"] {
        let source = try bitmap(width: width, height: height)
        guard let pointer = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing source pixels")
        }
        for y in 0..<height { for x in 0..<width {
            let at = y * source.bytesPerRow + x * 4
            if fixture == "overlay" {
                let alpha = x < 12 || y < 12 || x > 80 || y > 58 ? 0 : 160
                pointer[at] = UInt8((x * 255 / (width - 1)) * alpha / 255)
                pointer[at + 1] = UInt8((y * 255 / (height - 1)) * alpha / 255)
                pointer[at + 2] = UInt8(220 * alpha / 255)
                pointer[at + 3] = UInt8(alpha)
            } else {
                let impulse = Int(fixture.split(separator: "-").last ?? "")
                let hit = fixture.hasPrefix("vertical") ? y == impulse : x == impulse
                pointer[at] = hit ? 255 : 127
                pointer[at + 1] = 63
                pointer[at + 2] = 191
                pointer[at + 3] = 255
            }
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make source image") }
        let floatSource = try bitmap(width: width, height: height, floating: true)
        guard let floats = floatSource.data?.assumingMemoryBound(to: Float.self) else {
            throw CaptureError.failed("Missing floating-point source pixels")
        }
        for y in 0..<height { for x in 0..<(width * 4) {
            floats[y * floatSource.bytesPerRow / MemoryLayout<Float>.size + x] = Float(pointer[y * source.bytesPerRow + x]) / 255
        } }
        guard let floatImage = floatSource.makeImage() else { throw CaptureError.failed("Cannot make floating-point source image") }
        for block in [1, 2, 6] {
            let small = try sampleCoreGraphics(image, block: block)
            let floatSmall = try sampleCoreGraphics(floatImage, block: block, floating: true)
            var alternatives = [String: Any]()
            for (name, flags) in [("default", vImage_Flags(kvImageNoFlags)),
                                  ("high", vImage_Flags(kvImageHighQualityResampling))] {
                let scaled = try bitmap(width: small.width, height: small.height)
                var inputBuffer = vImage_Buffer(data: source.data, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: source.bytesPerRow)
                var outputBuffer = vImage_Buffer(data: scaled.data, height: vImagePixelCount(small.height),
                    width: vImagePixelCount(small.width), rowBytes: scaled.bytesPerRow)
                let error = vImageScale_ARGB8888(&inputBuffer, &outputBuffer, nil, flags)
                guard error == kvImageNoError else { throw CaptureError.failed("vImage scale failed: \(error)") }
                alternatives[name] = try describe(scaled)
            }
            var affine = [String: Any]()
            let ratio = 1.0 / Double(block)
            for (geometry, scaleX, scaleY) in [("nominal", ratio, ratio),
                    ("corners", Double(small.width - 1) / Double(width - 1),
                     Double(small.height - 1) / Double(height - 1))] {
                for (phaseName, phase) in [("zero", 0.0), ("positive-half", 0.5), ("negative-half", -0.5)] {
                    for (qualityName, quality) in [("default", vImage_Flags(kvImageNoFlags)),
                                                   ("high", vImage_Flags(kvImageHighQualityResampling))] {
                        for (edgeName, edge) in [("extend", vImage_Flags(kvImageEdgeExtend)),
                                                 ("transparent", vImage_Flags(kvImageBackgroundColorFill))] {
                            let prefix = geometry == "nominal" ? "" : "corners-"
                            affine["\(prefix)\(phaseName)-\(qualityName)-\(edgeName)"] = try captureAffine(source,
                                width: small.width, height: small.height, scaleX: scaleX, scaleY: scaleY,
                                translationX: (1 - scaleX) * phase, translationY: (1 - scaleY) * phase,
                                flags: quality | edge)
                        }
                    }
                }
            }
            cases.append(["fixture": fixture, "block": block, "input": try describe(source),
                          "output": try describe(small), "vImage": alternatives, "vImageAffine": affine,
                          "floating": ["format": "extended-sRGB premultiplied RGBAFloat32LE",
                                       "input": try describe(floatSource), "output": try describe(floatSmall)]])
        }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "format": "sRGB premultiplied RGBA8; packed bitmap-memory rows", "quality": "high",
            "recipe": "BrushRaster.context and the downsample stage of DitherSettings.apply", "cases": cases,
            "sourceOver": try captureBlend(.normal), "exclusion": try captureBlend(.exclusion),
            "hue": try captureBlend(.hue), "saturation": try captureBlend(.saturation),
            "nonseparablePairs": try captureNonseparablePairs(),
            "text": try captureText(), "textGeometry": try captureTextGeometry(),
            "textParagraphGeometry": try captureTextParagraphGeometry(), "textFallbackFonts": try captureTextFallbackFonts()]
}

do {
    let result = try capture()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Core Graphics capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Core Graphics capture requires native macOS.\n".utf8))
exit(1)
#endif
