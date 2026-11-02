import Foundation
import CoreGraphics

/// The PDFKit page-rotation surface used by upstream's import fixtures. Reading and rendering use the same PDF
/// engine as Core Graphics; writing appends updated page dictionaries, preserving every original stream byte.
public final class PDFPage {
    public var rotation: Int
    init(rotation: Int) { self.rotation = rotation }
}

public final class PDFDocument {
    private let data: Data
    private let pages: [PDFPage]
    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let document = CGPDFDocument(url), document.isUnlocked else { return nil }
        self.data = data
        pages = (1...max(1, document.numberOfPages)).compactMap { document.page(at: $0).map { PDFPage(rotation: Int($0.rotationAngle)) } }
    }
    public func page(at index: Int) -> PDFPage? { pages.indices.contains(index) ? pages[index] : nil }

    public func write(to url: URL) -> Bool {
        guard let text = String(data: data, encoding: .isoLatin1) else { return false }
        func captures(_ pattern: String, in source: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
                (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: source).map { String(source[$0]) } ?? "" }
            }
        }
        let objects = captures("(?s)([0-9]+)\\s+([0-9]+)\\s+obj\\s*(.*?)\\s*endobj", in: text)
        var byID: [Int: [String]] = [:]
        for object in objects { if let id = Int(object[1]) { byID[id] = object } }
        guard let root = captures("/Root\\s+([0-9]+)\\s+([0-9]+)\\s+R", in: text).last,
              let catalog = Int(root[1]).flatMap({ byID[$0] }),
              let tree = captures("/Pages\\s+([0-9]+)\\s+[0-9]+\\s+R", in: catalog[3]).first,
              let treeID = Int(tree[1]),
              let prior = captures("startxref\\s+([0-9]+)", in: text).last else { return false }
        var ordered: [[String]] = [], visited = Set<Int>()
        func walk(_ id: Int) -> Bool {
            guard visited.insert(id).inserted, let object = byID[id] else { return false }
            if !captures("/Type\\s*/Page\\b", in: object[3]).isEmpty { ordered.append(object); return true }
            guard let kids = captures("/Kids\\s*\\[([^]]*)\\]", in: object[3]).first else { return false }
            for reference in captures("([0-9]+)\\s+[0-9]+\\s+R", in: kids[1]) {
                guard let child = Int(reference[1]), walk(child) else { return false }
            }
            return true
        }
        guard walk(treeID), ordered.count == pages.count else { return false }
        var output = data
        output.append(Data("\n".utf8))
        var offsets: [(id: Int, generation: Int, offset: Int)] = []
        for (index, object) in ordered.enumerated() {
            guard let id = Int(object[1]), let generation = Int(object[2]) else { return false }
            var body = object[3].replacingOccurrences(of: "/Rotate\\s+-?[0-9]+", with: "", options: .regularExpression)
            body.insert(contentsOf: " /Rotate \(((pages[index].rotation % 360) + 360) % 360) ", at: body.index(body.startIndex, offsetBy: 2))
            offsets.append((id, generation, output.count))
            output.append(Data("\(id) \(generation) obj\n\(body)\nendobj\n".utf8))
        }
        let xref = output.count
        output.append(Data("xref\n".utf8))
        for entry in offsets.sorted(by: { $0.id < $1.id }) {
            output.append(Data(String(format: "%d 1\n%010d %05d n \n", entry.id, entry.offset, entry.generation).utf8))
        }
        let size = (byID.keys.max() ?? 0) + 1
        output.append(Data("trailer\n<< /Size \(size) /Root \(root[1]) \(root[2]) R /Prev \(prior[1]) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        do { try output.write(to: url, options: .atomic); return true } catch { return false }
    }
}
