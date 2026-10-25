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
    var recipes: [(String, String, Double, Double, Double, Double, Int)] = [
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
        ("bidi-first-strong", "A\u{2068}BC\u{2069} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-back-to-back", "A\u{202E}BC\u{202C}\u{202E}DE\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-empty", "A\u{202E}\u{202C} Ω", 12.5, 0, 0, 1e7, 0),
        ("bidi-wrapped", "A\u{202E}BC\u{202C} Ω", 12.5, 0, 0, 20, 0)]
    let trackingControls = recipes.filter { $0.0.hasPrefix("bidi-") && $0.0 != "bidi-controls" && $0.4 == 0 }
    recipes += trackingControls.map { (name, text, size, height, _, width, alignment) in
        (name + "-tracking", text, size, height, 1.25, width, alignment)
    }
    recipes += [("bidi-negative-tracking", "A\u{202E}BC\u{202C} Ω", 12.5, 0, -0.75, 1e7, 0),
                ("bidi-nested-negative-tracking", "A\u{202E}B\u{202D}CD\u{202C}E\u{202C} Ω", 12.5, 0, -0.75, 1e7, 0),
                ("bidi-initial-negative-tracking", "\u{202E}Ag Ω\u{202C}", 12.5, 0, -0.75, 1e7, 0)]
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

// Keep stroke geometry independent of the application's shape builder and image export.
// Fractional phases, caps and nonuniform transforms expose scan-conversion differences.
func captureStrokeCoverage() throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    let angles = [0.0, 35.0, -35.0, 90.0, 36.86989764584402, 53.13010235415598]
    let transforms: [(String, CGAffineTransform)] = [
        ("identity", .identity),
        ("translated", CGAffineTransform(translationX: 0.375, y: -0.25)),
        ("affine", CGAffineTransform(a: 0.8, b: 0.15, c: -0.1, d: 0.75, tx: 9, ty: 4))
    ]
    func append(_ name: String, degrees: Double, width: Double, phase: Double,
                transform: (String, CGAffineTransform), cap: (String, CGLineCap), canonical: Bool = false) throws {
        let angle = degrees * .pi / 180
        let start = canonical ? CGPoint(x: 8, y: 8)
            : CGPoint(x: 48 + phase - 26 * cos(angle), y: 36 + phase - 26 * sin(angle))
        let end = canonical ? CGPoint(x: 72, y: 56)
            : CGPoint(x: 48 + phase + 26 * cos(angle), y: 36 + phase + 26 * sin(angle))
        let rgba = canonical ? [0.0, 0, 0, 1] : [0.2, 0.65, 0.9, 0.7]
        let context = try bitmap(width: 96, height: 72)
        context.concatenate(transform.1)
        context.setShouldAntialias(true)
        context.setLineWidth(width)
        context.setLineCap(cap.1)
        context.setStrokeColor(CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]))
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        let t = transform.1
        cases.append(["name": name, "degrees": degrees, "width": width, "phase": phase,
                      "start": [start.x, start.y], "end": [end.x, end.y], "rgba": rgba,
                      "cap": cap.0, "transformName": transform.0,
                      "transform": [t.a, t.b, t.c, t.d, t.tx, t.ty], "output": try describe(context)])
    }
    for (index, angle) in angles.enumerated() {
        for width in [0.5, 1.0, 1.5, 2.0, 3.0, 7.0] {
            for phase in [0.0, 0.25] {
                try append("angle-\(index)-width-\(width)-phase-\(phase)", degrees: angle, width: width,
                           phase: phase, transform: transforms[0], cap: ("butt", .butt))
            }
        }
        for transform in transforms.dropFirst() {
            try append("\(transform.0)-angle-\(index)", degrees: angle, width: 3, phase: 0,
                       transform: transform, cap: ("butt", .butt))
        }
    }
    for (name, cap) in [("round", CGLineCap.round), ("square", CGLineCap.square)] {
        for angle in [0.0, 35.0, 90.0] {
            try append("\(name)-\(angle)", degrees: angle, width: 3, phase: 0,
                       transform: transforms[0], cap: (name, cap))
        }
    }
    try append("canonical-line", degrees: angles[4], width: 3, phase: 0,
               transform: transforms[0], cap: ("butt", .butt), canonical: true)
    return cases
}

func describePath(_ path: CGPath) -> [[String: Any]] {
    var segments = [[String: Any]]()
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        let verb: String, count: Int
        switch element.type {
        case .moveToPoint: verb = "move"; count = 1
        case .addLineToPoint: verb = "line"; count = 1
        case .addQuadCurveToPoint: verb = "quad"; count = 2
        case .addCurveToPoint: verb = "cubic"; count = 3
        case .closeSubpath: verb = "close"; count = 0
        @unknown default: verb = "unknown"; count = 0
        }
        let points = (0..<count).map { [element.points[$0].x, element.points[$0].y] }
        segments.append(["verb": verb, "points": points])
    }
    return segments
}

func rebuildCoveragePath(_ source: CGPath, transform: CGAffineTransform = .identity) -> CGPath {
    let result = CGMutablePath()
    source.applyWithBlock { pointer in
        let element = pointer.pointee
        func point(_ index: Int) -> CGPoint { element.points[index].applying(transform) }
        switch element.type {
        case .moveToPoint: result.move(to: point(0))
        case .addLineToPoint: result.addLine(to: point(0))
        case .addQuadCurveToPoint: result.addQuadCurve(to: point(1), control: point(0))
        case .addCurveToPoint:
            result.addCurve(to: point(2), control1: point(0), control2: point(1))
        case .closeSubpath: result.closeSubpath()
        @unknown default: break
        }
    }
    return result
}

// The same smooth-corner geometry as ShapeKind; keep the native path elements
// in the artifact so path construction and pixel coverage can be tested separately.
func smoothCoverageRectangle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let smoothing = min(CGFloat(0.6), max(0, min(rect.width, rect.height) / (2 * radius) - 1))
    guard smoothing > 0 else {
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    let reach = (1 + smoothing) * radius, angle = smoothing * .pi / 4
    let tangent = radius * tan(angle / 2), c = tangent * cos(angle), d = tangent * sin(angle)
    let arcLength = radius * sqrt(2) * sin((1 - smoothing) * .pi / 4)
    let b = (reach - arcLength - c - d) / 3, a = 2 * b
    let path = CGMutablePath()
    let corners = [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                   CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
    for (index, corner) in corners.enumerated() {
        let transform = CGAffineTransform(translationX: corner.x, y: corner.y).rotated(by: CGFloat(index) * .pi / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
        if index == 0 { path.move(to: point(-reach, 0)) } else { path.addLine(to: point(-reach, 0)) }
        path.addCurve(to: point(-reach + a + b + c, d),
                      control1: point(-reach + a, 0), control2: point(-reach + a + b, 0))
        path.addArc(center: CGPoint(x: -radius, y: radius), radius: radius,
                    startAngle: -.pi / 2 + angle, endAngle: -angle, clockwise: false, transform: transform)
        path.addCurve(to: point(0, reach), control1: point(0, reach - a - b), control2: point(0, reach - a))
    }
    path.closeSubpath()
    return path
}

func reorderedLinearCoveragePath(_ source: CGPath, reversed: Bool) throws -> CGPath {
    var points = [CGPoint]()
    var valid = true
    source.applyWithBlock { pointer in
        let element = pointer.pointee
        switch element.type {
        case .moveToPoint:
            if !points.isEmpty { valid = false }
            points.append(element.points[0])
        case .addLineToPoint: points.append(element.points[0])
        case .closeSubpath: break
        default: valid = false
        }
    }
    if points.count > 1, points.first == points.last { points.removeLast() }
    guard valid, points.count >= 3 else { throw CaptureError.failed("Expected one linear coverage contour") }
    if reversed {
        points.reverse()
    } else {
        let offset = points.count / 2
        points = Array(points.dropFirst(offset)) + Array(points.prefix(offset))
    }
    let result = CGMutablePath()
    result.move(to: points[0])
    for point in points.dropFirst() { result.addLine(to: point) }
    result.closeSubpath()
    return result
}

func captureCurveCoverage() throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    let sizes = [CGSize(width: 4, height: 4), CGSize(width: 12, height: 8),
                 CGSize(width: 31.5, height: 23.25), CGSize(width: 64, height: 48),
                 CGSize(width: 63.5, height: 47.25)]
    let transforms: [(String, CGAffineTransform)] = [
        ("identity", .identity), ("translated", CGAffineTransform(translationX: 0.375, y: -0.25)),
        ("affine", CGAffineTransform(a: 0.8, b: 0.15, c: -0.1, d: 0.75, tx: 9, ty: 4))
    ]
    func append(_ name: String, family: String, path: CGPath, transform: (String, CGAffineTransform),
                flatness: Double? = nil) throws {
        let context = try bitmap(width: 96, height: 72)
        context.concatenate(transform.1)
        context.setShouldAntialias(true)
        if let flatness { context.setFlatness(flatness) }
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.5, alpha: 0.7))
        context.addPath(path)
        context.fillPath()
        let t = transform.1
        let rebuiltPath = rebuildCoveragePath(path)
        let rebuilt = try bitmap(width: 96, height: 72)
        rebuilt.concatenate(transform.1)
        rebuilt.setShouldAntialias(true)
        if let flatness { rebuilt.setFlatness(flatness) }
        rebuilt.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.5, alpha: 0.7))
        rebuilt.addPath(rebuiltPath)
        rebuilt.fillPath()
        var flattenedCopies = [[String: Any]]()
        var coverageControls = [[String: Any]]()
        for threshold in [0.025, 0.05, 0.0625, 0.075, 0.1, 0.25, 0.5, 0.6, 1.0, 10.0] {
            let copy: CGPath? = path.flattened(threshold: threshold)
            guard let copy else { throw CaptureError.failed("Cannot flatten native path") }
            let target = try bitmap(width: 96, height: 72)
            target.concatenate(transform.1)
            target.setShouldAntialias(true)
            target.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.5, alpha: 0.7))
            target.addPath(copy)
            target.fillPath()
            flattenedCopies.append(["threshold": threshold, "path": describePath(copy), "output": try describe(target)])
            if threshold == 0.1 {
                for (label, alpha, pretransformed, floating) in [
                    ("opaque", 1.0, false, false), ("alpha-0.7", 0.7, false, false),
                    ("alpha-0.5", 0.5, false, false), ("alpha-0.25", 0.25, false, false),
                    ("transformed-opaque", 1.0, true, false), ("transformed-color", 0.7, true, false),
                    ("floating-opaque", 1.0, false, true)
                ] {
                    let sample = try bitmap(width: 96, height: 72, floating: floating)
                    sample.setShouldAntialias(true)
                    if pretransformed {
                        sample.addPath(rebuildCoveragePath(copy, transform: transform.1))
                    } else {
                        sample.concatenate(transform.1)
                        sample.addPath(copy)
                    }
                    let color = label == "transformed-color" ? [0.8, 0.3, 0.5] : [1.0, 1, 1]
                    sample.setFillColor(CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: alpha))
                    sample.fillPath()
                    coverageControls.append(["name": label, "alpha": alpha, "pretransformed": pretransformed,
                                             "floating": floating, "output": try describe(sample)])
                }
                for (label, reversed) in [("reversed-opaque", true), ("rotated-opaque", false)] {
                    let sample = try bitmap(width: 96, height: 72)
                    sample.concatenate(transform.1)
                    sample.setShouldAntialias(true)
                    let reordered = try reorderedLinearCoveragePath(copy, reversed: reversed)
                    sample.addPath(reordered)
                    sample.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                    sample.fillPath()
                    coverageControls.append(["name": label, "alpha": 1.0, "pretransformed": false,
                                             "floating": false, "path": describePath(reordered),
                                             "output": try describe(sample)])
                }
            }
        }
        cases.append(["name": name, "family": family, "path": describePath(path), "flattened": flattenedCopies,
                      "coverageControls": coverageControls,
                      "rebuiltPath": describePath(rebuiltPath), "rebuiltOutput": try describe(rebuilt),
                      "transformName": transform.0, "transform": [t.a, t.b, t.c, t.d, t.tx, t.ty],
                      "flatness": flatness.map { String($0) } ?? "default", "rgba": [0.8, 0.3, 0.5, 0.7],
                      "output": try describe(context)])
    }
    for family in ["ellipse", "rounded", "smooth"] {
        for (index, size) in sizes.enumerated() {
            for phase in [0.0, 0.25] {
                let rect = CGRect(x: 8 + phase, y: 8 + phase, width: size.width, height: size.height)
                let radius = min(CGFloat(12), rect.width / 2, rect.height / 2)
                let path = family == "ellipse" ? CGPath(ellipseIn: rect, transform: nil)
                    : family == "rounded" ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    : smoothCoverageRectangle(rect, radius: radius)
                for transform in transforms {
                    try append("\(family)-size-\(index)-phase-\(phase)-\(transform.0)", family: family,
                               path: path, transform: transform)
                }
                if index == 3 && phase == 0 {
                    for flatness in [0.01, 0.1, 0.6, 1.0, 10.0] {
                        try append("\(family)-flatness-\(flatness)", family: family,
                                   path: path, transform: transforms[0], flatness: flatness)
                    }
                }
            }
        }
    }
    for family in ["quad-cap", "cubic-cap"] {
        for phase in [0.0, 0.25] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 8 + phase, y: 48 + phase))
            if family == "quad-cap" {
                path.addQuadCurve(to: CGPoint(x: 72 + phase, y: 48 + phase), control: CGPoint(x: 40 + phase, y: -8 + phase))
            } else {
                path.addCurve(to: CGPoint(x: 72 + phase, y: 48 + phase),
                              control1: CGPoint(x: 8 + phase, y: phase), control2: CGPoint(x: 72 + phase, y: phase))
            }
            path.closeSubpath()
            try append("\(family)-phase-\(phase)", family: family, path: path, transform: transforms[0])
        }
    }
    return cases
}

func captureStrokeOutlines(_ strokes: [[String: Any]]) throws -> [[String: Any]] {
    try strokes.map { stroke in
        guard let start = stroke["start"] as? [CGFloat], let end = stroke["end"] as? [CGFloat],
              let t = stroke["transform"] as? [CGFloat], let rgba = stroke["rgba"] as? [Double],
              let width = stroke["width"] as? Double, let capName = stroke["cap"] as? String else {
            throw CaptureError.failed("Invalid stroke recipe for outline capture")
        }
        let cap: CGLineCap = capName == "round" ? .round : capName == "square" ? .square : .butt
        let source = CGMutablePath()
        source.move(to: CGPoint(x: start[0], y: start[1]))
        source.addLine(to: CGPoint(x: end[0], y: end[1]))
        let outline = source.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .miter, miterLimit: 10)
        let context = try bitmap(width: 96, height: 72)
        context.concatenate(CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5]))
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]))
        context.addPath(outline)
        context.fillPath()
        return ["name": stroke["name"]!, "path": describePath(outline), "output": try describe(context)]
    }
}

func captureSamplingLinearity() throws -> [[String: Any]] {
    let width = 96, height = 72
    var cases = [[String: Any]]()
    func append(_ mode: String, axis: Int, position: Int = 48, base: Double = 0, amplitude: Double = 1) throws {
        let source = try bitmap(width: width, height: height, floating: true)
        guard let pixels = source.data?.assumingMemoryBound(to: Float.self) else {
            throw CaptureError.failed("Missing sampling-linearity source")
        }
        let length = axis == 0 ? width : height
        for y in 0..<height { for x in 0..<width {
            let coordinate = axis == 0 ? x : y
            let value = mode == "ramp" ? Double(coordinate) / Double(length - 1)
                : mode == "checker" ? Double(coordinate % 2)
                : base + (coordinate == position ? amplitude : 0)
            let at = y * source.bytesPerRow / MemoryLayout<Float>.size + x * 4
            pixels[at] = Float(value)
            pixels[at + 1] = 0.25
            pixels[at + 2] = 0.75
            pixels[at + 3] = 1
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make sampling-linearity image") }
        for block in [2, 6] {
            let output = try sampleCoreGraphics(image, block: block, floating: true)
            cases.append(["mode": mode, "axis": axis, "position": position, "base": base,
                          "amplitude": amplitude, "block": block,
                          "input": try describe(source), "output": try describe(output)])
        }
    }
    for axis in [0, 1] {
        for position in [48, 49, 50, 51] {
            for base in [0.0, 0.5] {
                for amplitude in [0.25, 0.5, 1.0] {
                    try append("impulse", axis: axis, position: position, base: base, amplitude: amplitude)
                }
            }
        }
        try append("ramp", axis: axis)
        try append("checker", axis: axis)
    }
    return cases
}

func captureSamplingGeometry(alphaMode: String = "opaque",
                             sizes: [(Int, Int)] = [(17, 13), (65, 49), (97, 73)]) throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    for (width, height) in sizes {
        for floating in [false, true] {
            for mode in ["constant", "ramps", "checker", "corners"] {
                let source = try bitmap(width: width, height: height, floating: floating)
                guard let data = source.data else { throw CaptureError.failed("Missing sampling-geometry source") }
                for y in 0..<height { for x in 0..<width {
                    let values: [Double]
                    switch mode {
                    case "constant": values = [0.25, 0.5, 0.75, 1]
                    case "ramps": values = [Double(x) / Double(width - 1), Double(y) / Double(height - 1), 0.5, 1]
                    case "checker": values = [Double(x % 2), Double(y % 2), Double((x + y) % 2), 1]
                    default: values = [x == width - 1 && y == height - 1 ? 1 : 0,
                                       x == 0 && y == height - 1 ? 1 : 0,
                                       x == width - 1 && y == 0 ? 1 : 0, 1]
                    }
                    let alpha = alphaMode == "half" ? 0.5
                        : alphaMode == "ramp" ? 0.25 + 0.75 * Double(x + y) / Double(width + height - 2) : 1
                    if floating {
                        let pixels = data.assumingMemoryBound(to: Float.self)
                        let at = y * source.bytesPerRow / MemoryLayout<Float>.size + x * 4
                        for c in 0..<4 { pixels[at + c] = Float(values[c] * alpha) }
                    } else {
                        let pixels = data.assumingMemoryBound(to: UInt8.self)
                        let at = y * source.bytesPerRow + x * 4
                        for c in 0..<4 { pixels[at + c] = UInt8((values[c] * alpha * 255).rounded()) }
                    }
                } }
                guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make sampling-geometry image") }
                for block in [2, 3, 6] {
                    for quality in ["none", "high"] {
                        let smallWidth = (width + block - 1) / block, smallHeight = (height + block - 1) / block
                        func draw(_ drawWidth: Double, _ drawHeight: Double) throws -> CGContext {
                            let output = try bitmap(width: smallWidth, height: smallHeight, floating: floating)
                            output.interpolationQuality = quality == "high" ? .high : .none
                            output.translateBy(x: 0, y: drawHeight)
                            output.scaleBy(x: 1, y: -1)
                            output.setBlendMode(.copy)
                            output.draw(image, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
                            return output
                        }
                        let fractional = try draw(Double(width) / Double(block), Double(height) / Double(block))
                        let aligned = try draw(Double(smallWidth), Double(smallHeight))
                        cases.append(["sourceWidth": width, "sourceHeight": height, "floating": floating,
                                      "mode": mode, "block": block, "quality": quality,
                                      "input": try describe(source), "output": try describe(fractional),
                                      "alignedOutput": try describe(aligned)])
                    }
                }
            }
        }
    }
    return cases
}

func captureSamplingAlphaGeometry() throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    for alphaMode in ["opaque", "half", "ramp"] {
        let sizes = alphaMode == "opaque" ? [(32, 24)] : [(17, 13), (32, 24), (65, 49), (97, 73)]
        let controls = try captureSamplingGeometry(alphaMode: alphaMode, sizes: sizes)
        for var control in controls {
            control["alphaMode"] = alphaMode
            cases.append(control)
        }
    }
    return cases
}

func captureSamplingCorners() throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    for (width, height) in [(17, 13), (32, 24), (65, 49), (96, 72), (97, 73)] {
        for floating in [false, true] {
            let source = try bitmap(width: width, height: height, floating: floating)
            guard let data = source.data else { throw CaptureError.failed("Missing sampling-corner source") }
            for y in 0..<height { for x in 0..<width {
                let alpha = 0.25 + 0.75 * Double(x + y) / Double(width + height - 2)
                let values = [Double(x) / Double(width - 1), Double(y) / Double(height - 1),
                              Double((x + 2 * y) % 5) / 4]
                if floating {
                    let pixels = data.assumingMemoryBound(to: Float.self)
                    let at = y * source.bytesPerRow / MemoryLayout<Float>.size + x * 4
                    for c in 0..<3 { pixels[at + c] = Float(values[c] * alpha) }
                    pixels[at + 3] = Float(alpha)
                } else {
                    let pixels = data.assumingMemoryBound(to: UInt8.self)
                    let at = y * source.bytesPerRow + x * 4
                    for c in 0..<3 { pixels[at + c] = UInt8((values[c] * alpha * 255).rounded()) }
                    pixels[at + 3] = UInt8((alpha * 255).rounded())
                }
            } }
            guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make sampling-corner image") }
            for block in [1, 2, 3, 6] {
                for quality in ["none", "high"] {
                    let output = try bitmap(width: (width + block - 1) / block,
                                            height: (height + block - 1) / block, floating: floating)
                    output.interpolationQuality = quality == "high" ? .high : .none
                    output.translateBy(x: 0, y: CGFloat(height) / CGFloat(block))
                    output.scaleBy(x: 1, y: -1)
                    output.setBlendMode(.copy)
                    output.draw(image, in: CGRect(x: 0, y: 0, width: Double(width) / Double(block),
                                                  height: Double(height) / Double(block)))
                    cases.append(["sourceWidth": width, "sourceHeight": height, "floating": floating,
                                  "block": block, "quality": quality, "input": try describe(source),
                                  "output": try describe(output)])
                }
            }
        }
    }
    return cases
}

func captureSamplingSignals() throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    for alpha in [255, 128] {
        let source = try bitmap(width: 320, height: 320)
        guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing sampling-signal source")
        }
        for y in 0..<320 { for x in 0..<320 {
            let at = y * source.bytesPerRow + x * 4
            for c in 0..<3 { pixels[at + c] = x % 5 < 2 ? UInt8(alpha) : 0 }
            pixels[at + 3] = UInt8(alpha)
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make sampling-signal image") }
        let output = try sampleCoreGraphics(image, block: 10)
        cases.append(["fixture": "period-5-two-white", "alpha": alpha, "block": 10,
                      "input": try describe(source), "output": try describe(output)])
    }
    return cases
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
    let strokes = try captureStrokeCoverage()
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "format": "sRGB premultiplied RGBA8; packed bitmap-memory rows", "quality": "high",
            "samplingLinearity": try captureSamplingLinearity(),
            "samplingCorners": try captureSamplingCorners(),
            "samplingSignals": try captureSamplingSignals(),
            "samplingGeometry": try captureSamplingGeometry(),
            "samplingAlphaGeometry": try captureSamplingAlphaGeometry(),
            "recipe": "BrushRaster.context and the downsample stage of DitherSettings.apply", "cases": cases,
            "sourceOver": try captureBlend(.normal), "exclusion": try captureBlend(.exclusion),
            "hue": try captureBlend(.hue), "saturation": try captureBlend(.saturation),
            "nonseparablePairs": try captureNonseparablePairs(),
            "strokeCoverage": strokes, "strokeOutlines": try captureStrokeOutlines(strokes),
            "curveCoverage": try captureCurveCoverage(),
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
