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

    init(mediaBox: CGRect, image: CGImage?) {
        self.mediaBox = mediaBox
        self.image = image
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
            pdf = PDFWriter.document(image: image, mediaBox: entry.mediaBox)
        } else {
            pdf = PDFWriter.empty(mediaBox: entry.mediaBox)
        }
        entry.consumer.data.setData(pdf)
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
        guard let image = page.image else { return }
        // Map the page's media box through the current CTM (ExportTests scales first), then blit
        // in device pixels. Avoids Skia/y-up fractional-user-space quirks for this hot path.
        drawPDFImage(image, mediaBox: page.mediaBox)
    }
}

private enum PDFWriter {
    static func empty(mediaBox: CGRect) -> Data {
        document(rgb: nil, width: 0, height: 0, mediaBox: mediaBox, alpha: nil)
    }

    static func document(image: CGImage, mediaBox: CGRect) -> Data {
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
        return document(rgb: rgb, width: w, height: h, mediaBox: mediaBox, alpha: alpha)
    }

    static func document(rgb: [UInt8]?, width: Int, height: Int, mediaBox: CGRect, alpha: [UInt8]?) -> Data {
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
            let content = String(format: "q %.6f 0 0 %.6f 0 0 cm /Im0 Do Q\n", Double(mw), Double(mh))
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
            obj("4 0 obj<< /Length 0 >>stream\nendstream\nendobj\n")
        }

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
        guard let width = intField("/Width ", in: text),
              let height = intField("/Height ", in: text),
              width > 0, height > 0 else {
            return [CGPDFPage(mediaBox: media, image: nil)]
        }
        let streams = flateStreams(in: bytes)
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
        return [CGPDFPage(mediaBox: media, image: image)]
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
