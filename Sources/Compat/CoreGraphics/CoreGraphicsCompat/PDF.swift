// PDF export surface used by ImageExporter.pdfData: CGDataConsumer + a CGContext that records one page and
// writes a minimal PDF embedding the page bitmap. Enough for File › Export As… PDF and headless smokes.

import Foundation

public final class CGDataConsumer: @unchecked Sendable {
    let data: NSMutableData
    public init?(data: NSMutableData) { self.data = data }
}

extension CGContext {
    private static var pdfBoxes: [ObjectIdentifier: (consumer: CGDataConsumer, mediaBox: CGRect)] = [:]
    private static let pdfLock = NSLock()

    /// PDF context: draws into a y-up bitmap the size of `mediaBox`, then `closePDF` embeds it.
    public convenience init?(consumer: CGDataConsumer, mediaBox: UnsafeMutablePointer<CGRect>,
                            _ auxiliaryInfo: CFDictionary?) {
        _ = auxiliaryInfo
        let box = mediaBox.pointee
        let w = max(1, Int(ceil(Double(box.width))))
        let h = max(1, Int(ceil(Double(box.height))))
        self.init(width: w, height: h, format: .rgba, yUp: true, render: nil)
        Self.pdfLock.lock()
        Self.pdfBoxes[ObjectIdentifier(self)] = (consumer, box)
        Self.pdfLock.unlock()
    }

    public func beginPDFPage(_ pageInfo: CFDictionary?) { _ = pageInfo }

    public func endPDFPage() {}

    public func closePDF() {
        Self.pdfLock.lock()
        let box = Self.pdfBoxes.removeValue(forKey: ObjectIdentifier(self))
        Self.pdfLock.unlock()
        guard let box else { return }
        let media = box.mediaBox
        guard let image = makeImage() else {
            box.consumer.data.setData(Self.emptyPDF(mediaBox: media) as Data)
            return
        }
        box.consumer.data.setData(Self.pdfEmbedding(image: image, mediaBox: media) as Data)
    }

    private static func emptyPDF(mediaBox: CGRect) -> NSData {
        let w = mediaBox.width, h = mediaBox.height
        let body = """
        %PDF-1.4
        1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
        2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
        3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Contents 4 0 R >>endobj
        4 0 obj<< /Length 0 >>stream
        endstream
        endobj
        xref
        0 5
        0000000000 65535 f 
        trailer<< /Size 5 /Root 1 0 R >>
        startxref
        0
        %%EOF
        """
        return Data(body.utf8) as NSData
    }

    /// One-page PDF with an RGB image XObject (8-bit, no compression) covering the media box.
    private static func pdfEmbedding(image: CGImage, mediaBox: CGRect) -> NSData {
        let w = image.width, h = image.height
        let bytes = image.portableImage.bytes
        var stream = Data()
        stream.reserveCapacity(w * h * 3)
        for y in 0..<h {
            let row = y * image.bytesPerRow
            for x in 0..<w {
                let i = row + x * 4
                stream.append(bytes[i])
                stream.append(bytes[i + 1])
                stream.append(bytes[i + 2])
            }
        }
        let mw = mediaBox.width, mh = mediaBox.height
        let imgObj = """
        5 0 obj<< /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(stream.count) >>stream\n
        """
        var pdf = Data()
        func append(_ s: String) { pdf.append(contentsOf: s.utf8) }
        append("%PDF-1.4\n")
        append("1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n")
        append("2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n")
        append("3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(mw) \(mh)] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>endobj\n")
        let content = "q \(mw) 0 0 \(mh) 0 0 cm /Im0 Do Q\n"
        append("4 0 obj<< /Length \(content.utf8.count) >>stream\n\(content)endstream\nendobj\n")
        append(imgObj)
        pdf.append(stream)
        append("\nendstream\nendobj\n")
        append("trailer<< /Root 1 0 R >>\n%%EOF\n")
        return pdf as NSData
    }
}
