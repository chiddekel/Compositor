// PDF export/import for ImageExporter.pdfData and ExportTests:
// CGDataConsumer writer (FlateDecode RGB + soft-mask alpha) + CGPDFDocument reader + drawPDFPage.

import Foundation

public final class CGDataConsumer: @unchecked Sendable {
    let data: NSMutableData
    public init?(data: NSMutableData) { self.data = data }
}

public enum CGPDFBox: Sendable {
    case mediaBox, cropBox, bleedBox, trimBox, artBox
}

public final class CGPDFPage: @unchecked Sendable {
    let mediaBox: CGRect
    /// Raster embedded in the page (compat; Apple exposes drawing only via `drawPDFPage`).
    public let image: CGImage?
    let fills: [(rect: CGRect, color: CGColor)]

    init(mediaBox: CGRect, image: CGImage?, fills: [(rect: CGRect, color: CGColor)] = []) {
        self.mediaBox = mediaBox
        self.image = image
        self.fills = fills
    }

    public func getBoxRect(_ box: CGPDFBox) -> CGRect {
        _ = box
        return mediaBox
    }
}

public final class CGPDFDocument: @unchecked Sendable {
    private let pages: [CGPDFPage]
    public var numberOfPages: Int { pages.count }

    public init?(_ provider: CGDataProvider) {
        guard let parsed = PDFParser.parse(provider.bytes) else { return nil }
        self.pages = parsed
    }

    public func page(at index: Int) -> CGPDFPage? {
        guard index >= 1, index <= pages.count else { return nil }
        return pages[index - 1]
    }
}

/// PDF context bookkeeping shared with `CGContext.draw` (full-res image, point-sized media box).
enum PDFRecording {
    struct Entry {
        let consumer: CGDataConsumer
        let mediaBox: CGRect
        var image: CGImage?
        var drawRect: CGRect?
        var fills = ""
    }
    private static var boxes: [ObjectIdentifier: Entry] = [:]
    private static let lock = NSLock()

    static func begin(_ context: CGContext, consumer: CGDataConsumer, mediaBox: CGRect) {
        lock.lock()
        boxes[ObjectIdentifier(context)] = Entry(consumer: consumer, mediaBox: mediaBox, image: nil, drawRect: nil)
        lock.unlock()
    }

    /// Returns true when `context` is a PDF consumer context (draw is recorded, not rasterized into the tiny bitmap).
    static func noteDrawIfNeeded(_ context: CGContext, image: CGImage, in rect: CGRect) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = boxes[ObjectIdentifier(context)] else { return false }
        entry.image = image
        entry.drawRect = rect
        boxes[ObjectIdentifier(context)] = entry
        return true
    }

    static func finish(_ context: CGContext) {
        lock.lock()
        let entry = boxes.removeValue(forKey: ObjectIdentifier(context))
        lock.unlock()
        guard let entry else { return }
        let pdf: Data
        if let image = entry.image {
            pdf = PDFWriter.document(image: image, mediaBox: entry.mediaBox, fills: entry.fills)
        } else {
            pdf = PDFWriter.empty(mediaBox: entry.mediaBox, fills: entry.fills)
        }
        entry.consumer.data.setData(pdf)
    }

    /// Preserve the export page's solid matte before its image, without changing CMYK image/profile data.
    static func noteFillIfNeeded(_ context: CGContext, rect: CGRect, color: CGColor) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = boxes[ObjectIdentifier(context)] else { return false }
        let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil)?.components ?? [0, 0, 0, 1]
        entry.fills += String(format: "q %.6f %.6f %.6f rg %.6f %.6f %.6f %.6f re f Q\n",
                             Double(rgb[0]), Double(rgb[1]), Double(rgb[2]), Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
        boxes[ObjectIdentifier(context)] = entry
        return true
    }
}

extension CGContext {
    public convenience init?(consumer: CGDataConsumer, mediaBox: UnsafeMutablePointer<CGRect>,
                            _ auxiliaryInfo: CFDictionary?) {
        _ = auxiliaryInfo
        let box = mediaBox.pointee
        // 1×1 placeholder — real pixels come from `draw(_:in:)` via PDFRecording.
        self.init(width: 1, height: 1, format: .rgba, yUp: true, render: nil)
        PDFRecording.begin(self, consumer: consumer, mediaBox: box)
    }

    public func beginPDFPage(_ pageInfo: CFDictionary?) { _ = pageInfo }
    public func endPDFPage() {}

    public func closePDF() { PDFRecording.finish(self) }

    public func drawPDFPage(_ page: CGPDFPage) {
        saveGState()
        defer { restoreGState() }
        for fill in page.fills {
            setFillColor(fill.color)
            self.fill(fill.rect)
        }
        guard let image = page.image else { return }
        // Map the page's media box through the current CTM (ExportTests scales first), then blit
        // in device pixels. Avoids Skia/y-up fractional-user-space quirks for this hot path.
        drawPDFImage(image, mediaBox: page.mediaBox)
    }
}

private enum PDFWriter {
    static func empty(mediaBox: CGRect, fills: String = "") -> Data {
        document(rgb: nil, width: 0, height: 0, mediaBox: mediaBox, alpha: nil, fills: fills)
    }

    static func document(image: CGImage, mediaBox: CGRect, fills: String = "") -> Data {
        // A CMYK image goes in as its inks, its profile embedded (ICCBased, four components), as print takes it.
        if image.colorSpace?.model == .cmyk, let profile = image.colorSpace?.iccData, let inks = image.dataProvider?.bytes,
           inks.count >= image.width * image.height * 4 {
            var packed = [UInt8](repeating: 0, count: image.width * image.height * 4)
            for y in 0..<image.height {
                for x in 0..<(image.width * 4) { packed[y * image.width * 4 + x] = inks[y * image.bytesPerRow + x] }
            }
            return document(cmyk: packed, profile: [UInt8](profile), width: image.width, height: image.height, mediaBox: mediaBox, fills: fills)
        }
        let w = image.width, h = image.height
        let bytes = image.portableImage.bytes
        var rgb = [UInt8]()
        rgb.reserveCapacity(w * h * 3)
        let bpp = max(1, image.bitsPerPixel / 8)
        var alpha = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let row = y * image.bytesPerRow
            for x in 0..<w {
                let i = row + x * bpp
                let pi = y * w + x
                if bpp >= 4 {
                    let a = bytes[i + 3]
                    alpha[pi] = a
                    if a == 0 {
                        rgb.append(0); rgb.append(0); rgb.append(0)
                    } else if a == 255 {
                        rgb.append(bytes[i]); rgb.append(bytes[i + 1]); rgb.append(bytes[i + 2])
                    } else {
                        rgb.append(UInt8(min(255, Int(bytes[i]) * 255 / Int(a))))
                        rgb.append(UInt8(min(255, Int(bytes[i + 1]) * 255 / Int(a))))
                        rgb.append(UInt8(min(255, Int(bytes[i + 2]) * 255 / Int(a))))
                    }
                } else if bpp >= 3 {
                    rgb.append(bytes[i]); rgb.append(bytes[i + 1]); rgb.append(bytes[i + 2])
                } else {
                    let g = bytes[i]
                    rgb.append(g); rgb.append(g); rgb.append(g)
                }
            }
        }
        return document(rgb: rgb, width: w, height: h, mediaBox: mediaBox, alpha: alpha, fills: fills)
    }

    static func document(cmyk: [UInt8], profile: [UInt8], width: Int, height: Int, mediaBox: CGRect, fills: String = "") -> Data {
        let mw = mediaBox.width, mh = mediaBox.height
        var objects: [Data] = []
        func obj(_ body: String) { objects.append(Data(body.utf8)) }
        func objStream(_ dict: String, _ stream: [UInt8]) {
            var data = Data("\(dict)stream\n".utf8)
            data.append(contentsOf: stream)
            data.append(contentsOf: "\nendstream\nendobj\n".utf8)
            objects.append(data)
        }
        let inks = Zlib.stored(cmyk), icc = Zlib.stored(profile)
        let content = fills + String(format: "q %.6f 0 0 %.6f 0 0 cm /Im0 Do Q\n", Double(mw), Double(mh))
        obj("1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n")
        obj("2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n")
        obj("3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(mw) \(mh)] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>endobj\n")
        obj("4 0 obj<< /Length \(content.utf8.count) >>stream\n\(content)endstream\nendobj\n")
        objStream("5 0 obj<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace [/ICCBased 6 0 R] /BitsPerComponent 8 /Filter /FlateDecode /Length \(inks.count) >>", inks)
        objStream("6 0 obj<< /N 4 /Alternate /DeviceCMYK /Filter /FlateDecode /Length \(icc.count) >>", icc)
        return assemble(objects)
    }

    static func document(rgb: [UInt8]?, width: Int, height: Int, mediaBox: CGRect, alpha: [UInt8]?, fills: String = "") -> Data {
        let mw = mediaBox.width, mh = mediaBox.height
        var objects: [Data] = []
        func obj(_ body: String) { objects.append(Data(body.utf8)) }
        func objStream(_ dict: String, _ stream: [UInt8]) {
            var data = Data("\(dict)stream\n".utf8)
            data.append(contentsOf: stream)
            data.append(contentsOf: "\nendstream\nendobj\n".utf8)
            objects.append(data)
        }

        obj("1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n")
        obj("2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n")

        if let rgb {
            let flate = Zlib.stored(rgb)
            let content = fills + String(format: "q %.6f 0 0 %.6f 0 0 cm /Im0 Do Q\n", Double(mw), Double(mh))
            if let alpha {
                let alphaFlate = Zlib.stored(alpha)
                obj("3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(mw) \(mh)] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>endobj\n")
                obj("4 0 obj<< /Length \(content.utf8.count) >>stream\n\(content)endstream\nendobj\n")
                objStream("5 0 obj<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 6 0 R /Length \(flate.count) >>", flate)
                objStream("6 0 obj<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length \(alphaFlate.count) >>", alphaFlate)
            } else {
                obj("3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(mw) \(mh)] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>endobj\n")
                obj("4 0 obj<< /Length \(content.utf8.count) >>stream\n\(content)endstream\nendobj\n")
                objStream("5 0 obj<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length \(flate.count) >>", flate)
            }
        } else {
            obj("3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(mw) \(mh)] /Contents 4 0 R >>endobj\n")
            obj("4 0 obj<< /Length \(fills.utf8.count) >>stream\n\(fills)endstream\nendobj\n")
        }
        return assemble(objects)
    }

    private static func assemble(_ objects: [Data]) -> Data {
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]
        for object in objects {
            offsets.append(pdf.count)
            pdf.append(object)
        }
        let xrefAt = pdf.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefAt)\n%%EOF\n"
        pdf.append(contentsOf: xref.utf8)
        return pdf
    }
}

private enum PDFParser {
    static func parse(_ bytes: [UInt8]) -> [CGPDFPage]? {
        guard let text = String(bytes: bytes, encoding: .isoLatin1), text.hasPrefix("%PDF") else { return nil }
        guard let media = mediaBox(in: text) else { return nil }
        let fills = pageFills(in: text)
        guard let width = intField("/Width ", in: text),
              let height = intField("/Height ", in: text),
              width > 0, height > 0 else {
            return [CGPDFPage(mediaBox: media, image: nil, fills: fills)]
        }
        let streams = flateStreams(in: bytes)
        // A CMYK page (ICCBased, four components): its inks shown through the embedded profile.
        if text.contains("/ICCBased"), text.contains("/N 4"), streams.count > 1,
           let inks = Zlib.inflateZlib(streams[0]), inks.count >= width * height * 4,
           let profile = Zlib.inflateZlib(streams[1]) {
            let colors = CGImage.colors(ofInks: inks, bytesPerRow: width * 4, width: width, height: height,
                                        profile: Data(profile), intent: .relativeColorimetric)
            let image = CGImage(PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: colors))
            return [CGPDFPage(mediaBox: media, image: image, fills: fills)]
        }
        guard let rgbFlate = streams.first, let rgb = Zlib.inflateZlib(rgbFlate),
              rgb.count >= width * height * 3 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let alpha: [UInt8]? = {
            guard streams.count > 1, let a = Zlib.inflateZlib(streams[1]), a.count >= width * height else { return nil }
            return a
        }()
        for i in 0..<(width * height) {
            let r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2]
            let a = alpha?[i] ?? 255
            if a == 255 {
                rgba[i * 4] = r; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = b; rgba[i * 4 + 3] = 255
            } else if a == 0 {
                rgba[i * 4] = 0; rgba[i * 4 + 1] = 0; rgba[i * 4 + 2] = 0; rgba[i * 4 + 3] = 0
            } else {
                rgba[i * 4] = UInt8(Int(r) * Int(a) / 255)
                rgba[i * 4 + 1] = UInt8(Int(g) * Int(a) / 255)
                rgba[i * 4 + 2] = UInt8(Int(b) * Int(a) / 255)
                rgba[i * 4 + 3] = a
            }
        }
        let image = CGImage(PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: rgba))
        return [CGPDFPage(mediaBox: media, image: image, fills: fills)]
    }

    /// The page-content rectangle fills emitted by our exporter, separate from binary image/profile streams.
    private static func pageFills(in text: String) -> [(rect: CGRect, color: CGColor)] {
        guard let reference = text.range(of: "/Contents ") else { return [] }
        let parts = text[reference.upperBound...].split(maxSplits: 3, whereSeparator: { $0.isWhitespace }).prefix(3)
        guard parts.count == 3, parts.last == "R",
              let object = Int(parts[parts.startIndex]), let generation = Int(parts[parts.index(after: parts.startIndex)]),
              let objectStart = text.range(of: "\(object) \(generation) obj"),
              let streamStart = text[objectStart.upperBound...].range(of: "stream\n"),
              let streamEnd = text[streamStart.upperBound...].range(of: "endstream") else { return [] }
        let content = String(text[streamStart.upperBound..<streamEnd.lowerBound])
        let number = "([-+0-9.]+)"
        let pattern = "q\\s+" + Array(repeating: number, count: 3).joined(separator: "\\s+")
            + "\\s+rg\\s+" + Array(repeating: number, count: 4).joined(separator: "\\s+") + "\\s+re\\s+f\\s+Q"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap { match in
            let values = (1...7).compactMap { index -> CGFloat? in
                guard let range = Range(match.range(at: index), in: content),
                      let value = Double(content[range]), value.isFinite else { return nil }
                return CGFloat(value)
            }
            guard values.count == 7 else { return nil }
            return (CGRect(x: values[3], y: values[4], width: values[5], height: values[6]),
                    CGColor(red: values[0], green: values[1], blue: values[2], alpha: 1))
        }
    }

    private static func mediaBox(in text: String) -> CGRect? {
        guard let range = text.range(of: "/MediaBox [") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let parts = rest[..<end].split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2] - parts[0], height: parts[3] - parts[1])
    }

    private static func intField(_ key: String, in text: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        let rest = text[range.upperBound...]
        var digits = ""
        for ch in rest {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
            else if ch == " " || ch == "\n" { continue }
            else { break }
        }
        return Int(digits)
    }

    private static func flateStreams(in bytes: [UInt8]) -> [[UInt8]] {
        let marker = Array("/Filter /FlateDecode".utf8)
        let streamTag = Array("stream\n".utf8)
        let endTag = Array("\nendstream".utf8)
        var result: [[UInt8]] = []
        var i = 0
        while i < bytes.count {
            guard let filterAt = find(marker, in: bytes, from: i) else { break }
            guard let streamAt = find(streamTag, in: bytes, from: filterAt) else { break }
            let dataStart = streamAt + streamTag.count
            guard let endAt = find(endTag, in: bytes, from: dataStart) else { break }
            result.append(Array(bytes[dataStart..<endAt]))
            i = endAt + endTag.count
        }
        return result
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from < hay.count else { return nil }
        let last = hay.count - needle.count
        var i = from
        while i <= last {
            if hay[i] == needle[0] {
                var ok = true
                for j in 1..<needle.count where hay[i + j] != needle[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }
}
