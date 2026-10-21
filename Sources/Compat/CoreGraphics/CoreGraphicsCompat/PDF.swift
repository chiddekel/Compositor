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
public let kCGPDFContextMediaBox = "MediaBox"

struct PDFPageRecord {
    let box: CGRect
    let image: CGImage?
    let fills: String
}

public final class CGPDFPage: @unchecked Sendable {
    let mediaBox: CGRect
    /// Raster embedded in the page (compat; Apple exposes drawing only via `drawPDFPage`).
    public var image: CGImage? { storedImage ?? embeddedPage?()?.image }
    private let storedImage: CGImage?
    private var embeddedPage: (() -> CGPDFPage?)?
    let fills: [(rect: CGRect, color: CGColor)]
    private var native: NativePDFDocument?
    private var nativeIndex = 0
    public private(set) var rotationAngle: Int32 = 0

    init(mediaBox: CGRect, image: CGImage?, fills: [(rect: CGRect, color: CGColor)] = []) {
        self.mediaBox = mediaBox
        storedImage = image
        self.fills = fills
    }

    public func getBoxRect(_ box: CGPDFBox) -> CGRect {
        _ = box
        return mediaBox
    }
    convenience init(document: NativePDFDocument, index: Int, box: CGRect, rotation: Int32, embeddedPage: (() -> CGPDFPage?)? = nil) {
        self.init(mediaBox: box, image: nil)
        native = document; nativeIndex = index; rotationAngle = rotation
        self.embeddedPage = embeddedPage
    }
    public func getDrawingTransform(_ box: CGPDFBox, rect: CGRect, rotate: Int32, preserveAspectRatio: Bool) -> CGAffineTransform {
        let source = getBoxRect(box)
        let angle = -CGFloat(rotationAngle + rotate) * .pi / 180
        let rotation = CGAffineTransform(rotationAngle: angle)
        let turned = source.applying(rotation)
        var sx = rect.width / turned.width, sy = rect.height / turned.height
        if preserveAspectRatio { sx = min(sx, sy); sy = sx }
        return CGAffineTransform(a: rotation.a * sx, b: rotation.b * sy, c: rotation.c * sx, d: rotation.d * sy,
            tx: rect.minX + (rect.width - turned.width * sx) / 2 - turned.minX * sx,
            ty: rect.minY + (rect.height - turned.height * sy) / 2 - turned.minY * sy)
    }
    func drawNative(in context: CGContext) -> Bool {
        guard let native else { return false }
        // Splash interpolates embedded images even at their original pixel size. Preserve the existing exact,
        // nearest-neighbor path for the simple one-image pages this compatibility exporter writes.
        if context.interpolationQuality == .none, rotationAngle == 0, let page = embeddedPage?() {
            context.drawPDFPage(page)
            return true
        }
        let ctm = context.ctm
        let width = max(1, Int(ceil(mediaBox.width * hypot(ctm.a, ctm.b))))
        let height = max(1, Int(ceil(mediaBox.height * hypot(ctm.c, ctm.d))))
        if let image = native.render(nativeIndex, width: width, height: height) {
            // An axis-aligned PDF raster is already in device pixel order; preserve exact nearest-neighbor
            // export roundtrips through the same blit used by the original compatibility PDF reader.
            if abs(ctm.b) < 1e-10, abs(ctm.c) < 1e-10, ctm.a > 0, ctm.d > 0 {
                context.drawPDFImage(image, mediaBox: mediaBox)
            } else { context.draw(image, in: mediaBox) }
        }
        return true
    }
}

public final class CGPDFDocument: @unchecked Sendable {
    private let pages: [CGPDFPage]
    private var lockedPageCount = 0
    public private(set) var isEncrypted = false
    public var isUnlocked: Bool { !isEncrypted }
    public var numberOfPages: Int { isEncrypted ? lockedPageCount : pages.count }

    public init?(_ provider: CGDataProvider) {
        if let native = NativePDFDocument(provider.bytes) {
            isEncrypted = native.isLocked
            lockedPageCount = max(1, native.count)
            pages = (0..<max(0, native.count)).compactMap { index in
                guard let info = native.page(index) else { return nil }
                return CGPDFPage(document: native, index: index, box: info.box, rotation: info.rotation,
                    embeddedPage: native.count == 1 ? { PDFParser.rasterExport(provider.bytes) } : nil)
            }
        } else {
            guard !NativePDFDocument.isAvailable else { return nil }
            guard let parsed = PDFParser.parse(provider.bytes) else { return nil }
            self.pages = parsed
        }
    }
    public convenience init?(_ url: CFURL) {
        guard let bytes = try? Data(contentsOf: url), let provider = CGDataProvider(data: bytes) else { return nil }
        self.init(provider)
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
        var pageBox: CGRect?
        var pages: [PDFPageRecord] = []
        var url: URL?
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
        if entry.pages.count > 1 {
            pdf = PDFWriter.document(pages: entry.pages)
        } else if let image = entry.image {
            pdf = PDFWriter.document(image: image, mediaBox: entry.pageBox ?? entry.mediaBox, fills: entry.fills)
        } else {
            pdf = PDFWriter.empty(mediaBox: entry.pageBox ?? entry.mediaBox, fills: entry.fills)
        }
        entry.consumer.data.setData(pdf)
        if let url = entry.url { try? pdf.write(to: url, options: .atomic) }
    }
    static func setURL(_ url: URL, for context: CGContext) {
        lock.lock(); defer { lock.unlock() }
        boxes[ObjectIdentifier(context)]?.url = url
    }
    static func beginPage(_ context: CGContext, info: CFDictionary?) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = boxes[ObjectIdentifier(context)] else { return }
        entry.image = nil; entry.drawRect = nil; entry.fills = ""; entry.pageBox = nil
        if let data = info?[kCGPDFContextMediaBox] as? Data, data.count == MemoryLayout<CGRect>.size {
            let box = data.withUnsafeBytes { $0.loadUnaligned(as: CGRect.self) }
            if box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 { entry.pageBox = box }
        }
        boxes[ObjectIdentifier(context)] = entry
    }
    static func endPage(_ context: CGContext) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = boxes[ObjectIdentifier(context)] else { return }
        entry.pages.append(PDFPageRecord(box: entry.pageBox ?? entry.mediaBox, image: entry.image, fills: entry.fills))
        boxes[ObjectIdentifier(context)] = entry
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
    public convenience init?(_ url: CFURL, mediaBox: UnsafeMutablePointer<CGRect>, _ auxiliaryInfo: CFDictionary?) {
        guard let consumer = CGDataConsumer(data: NSMutableData()) else { return nil }
        self.init(consumer: consumer, mediaBox: mediaBox, auxiliaryInfo)
        PDFRecording.setURL(url, for: self)
    }
    public convenience init?(consumer: CGDataConsumer, mediaBox: UnsafeMutablePointer<CGRect>,
                            _ auxiliaryInfo: CFDictionary?) {
        _ = auxiliaryInfo
        let box = mediaBox.pointee
        // 1×1 placeholder — real pixels come from `draw(_:in:)` via PDFRecording.
        self.init(width: 1, height: 1, format: .rgba, yUp: true, render: nil)
        PDFRecording.begin(self, consumer: consumer, mediaBox: box)
    }

    public func beginPDFPage(_ pageInfo: CFDictionary?) { PDFRecording.beginPage(self, info: pageInfo) }
    public func endPDFPage() { PDFRecording.endPage(self) }

    public func closePDF() { PDFRecording.finish(self) }

    public func drawPDFPage(_ page: CGPDFPage) {
        if page.drawNative(in: self) { return }
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
    static func document(pages: [PDFPageRecord]) -> Data {
        var objects = [Data("1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n".utf8), Data()]
        var kids: [String] = []
        func add(_ body: String) { objects.append(Data(body.utf8)) }
        func stream(_ id: Int, dictionary: String, bytes: [UInt8]) {
            var data = Data("\(id) 0 obj<< \(dictionary) /Length \(bytes.count) >>stream\n".utf8)
            data.append(contentsOf: bytes); data.append(Data("\nendstream\nendobj\n".utf8)); objects.append(data)
        }
        for page in pages {
            let id = objects.count + 1, contentID = id + 1, imageID = id + 2, maskID = id + 3
            kids.append("\(id) 0 R")
            var content = page.fills
            if page.image != nil {
                content += String(format: "q %.6f 0 0 %.6f %.6f %.6f cm /Im0 Do Q\n", Double(page.box.width),
                                  Double(page.box.height), Double(page.box.minX), Double(page.box.minY))
            }
            let resource = page.image == nil ? "" : "/Resources << /XObject << /Im0 \(imageID) 0 R >> >>"
            add("\(id) 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [\(page.box.minX) \(page.box.minY) \(page.box.maxX) \(page.box.maxY)] \(resource) /Contents \(contentID) 0 R >>endobj\n")
            stream(contentID, dictionary: "", bytes: Array(content.utf8))
            guard let image = page.image else { continue }
            let width = image.width, height = image.height
            if image.colorSpace?.model == .cmyk, let profile = image.colorSpace?.iccData, let inks = image.dataProvider?.bytes {
                let packed = (0..<height).flatMap { Array(inks[($0 * image.bytesPerRow)..<($0 * image.bytesPerRow + width * 4)]) }
                stream(imageID, dictionary: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace [/ICCBased \(maskID) 0 R] /BitsPerComponent 8 /Filter /FlateDecode", bytes: Zlib.stored(packed))
                stream(maskID, dictionary: "/N 4 /Alternate /DeviceCMYK /Filter /FlateDecode", bytes: Zlib.stored(Array(profile)))
            } else {
                let bytes = image.portableImage.bytes, bpp = max(1, image.bitsPerPixel / 8)
                var rgb = [UInt8](), alpha = [UInt8]()
                for y in 0..<height { for x in 0..<width {
                    let offset = y * image.bytesPerRow + x * bpp, a = bpp >= 4 ? bytes[offset + 3] : 255
                    alpha.append(a)
                    for channel in 0..<3 {
                        let value = bytes[offset + (bpp >= 3 ? channel : 0)]
                        rgb.append(a == 0 ? 0 : UInt8(min(255, Int(value) * 255 / Int(a))))
                    }
                } }
                stream(imageID, dictionary: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask \(maskID) 0 R /Filter /FlateDecode", bytes: Zlib.stored(rgb))
                stream(maskID, dictionary: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", bytes: Zlib.stored(alpha))
            }
        }
        objects[1] = Data("2 0 obj<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>endobj\n".utf8)
        return assemble(objects)
    }
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
    /// Recognizes the exporter's full-page raster plus optional solid mattes. Additional operators, compressed
    /// content, rotations or different resources stay with the general PDF engine rather than losing content.
    static func rasterExport(_ bytes: [UInt8]) -> CGPDFPage? {
        guard let text = String(bytes: bytes, encoding: .isoLatin1), !text.contains("/Rotate"),
              text.contains("/Im0 5 0 R"), text.contains("/Contents 4 0 R"),
              let box = mediaBox(in: text), let content = pageContent(in: text) else { return nil }
        let n = "[-+0-9.]+"
        let fill = "q\\s+(?:" + n + "\\s+){3}rg\\s+(?:" + n + "\\s+){4}re\\s+f\\s+Q\\s*"
        let drawing = content.replacingOccurrences(of: "^(?:\\s*" + fill + ")*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^q\\s+(" + n + ")\\s+0\\s+0\\s+(" + n + ")\\s+0\\s+0\\s+cm\\s+/Im0\\s+Do\\s+Q$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: drawing, range: NSRange(drawing.startIndex..., in: drawing)),
              let xr = Range(match.range(at: 1), in: drawing), let yr = Range(match.range(at: 2), in: drawing),
              let width = Double(drawing[xr]), let height = Double(drawing[yr]),
              abs(width - box.width) < 1e-6, abs(height - box.height) < 1e-6,
              let page = parse(bytes)?.first, page.image != nil else { return nil }
        return page
    }

    static func parse(_ bytes: [UInt8]) -> [CGPDFPage]? {
        guard let text = String(bytes: bytes, encoding: .isoLatin1), text.hasPrefix("%PDF") else { return nil }
        guard let media = mediaBox(in: text) else { return nil }
        let fills = pageFills(in: text)
        guard let width = intField("/Width ", in: text),
              let height = intField("/Height ", in: text),
              width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 512_000_000 else {
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
        guard let content = pageContent(in: text) else { return [] }
        return fills(in: content)
    }
    private static func pageContent(in text: String) -> String? {
        guard let reference = text.range(of: "/Contents ") else { return nil }
        let parts = text[reference.upperBound...].split(maxSplits: 3, whereSeparator: { $0.isWhitespace }).prefix(3)
        guard parts.count == 3, parts.last == "R",
              let object = Int(parts[parts.startIndex]), let generation = Int(parts[parts.index(after: parts.startIndex)]),
              let objectStart = text.range(of: "\(object) \(generation) obj"),
              let streamStart = text[objectStart.upperBound...].range(of: "stream\n"),
              let streamEnd = text[streamStart.upperBound...].range(of: "endstream") else { return nil }
        return String(text[streamStart.upperBound..<streamEnd.lowerBound])
    }
    private static func fills(in content: String) -> [(rect: CGRect, color: CGColor)] {
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
