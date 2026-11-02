import Foundation

/// The fonts installed on this machine, by the names documents use for them — PostScript name, full name, family —
/// read from each font file's own `name` table, the way AppKit resolves `NSFont(name:size:)`. Scanned once, lazily.
///
/// A few macOS core families are always reported: upstream code (and the documents it writes) assumes them, and on
/// Linux the text backend substitutes a metric-compatible face for them, so treating them as missing would be wrong.
enum InstalledFonts {
    static func contains(_ name: String) -> Bool {
        let key = normalized(name)
        if coreFamilies.contains(where: { key == $0 || key.hasPrefix($0 + "-") }) { return true }
        return catalog.aliases[key] != nil
    }

    static func familyName(_ name: String) -> String? { catalog.aliases[normalized(name)] }
    static var postScriptNames: [String] { catalog.faces.values.flatMap { $0 }.sorted() }
    static func members(ofFamily family: String) -> [String] {
        catalog.faces[normalized(familyName(family) ?? family)]?.sorted() ?? []
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private static let coreFamilies: [String] = [
        "system", "monospace", ".appleSystemUIFont", "helvetica", "helveticaneue", "arial", "arialmt", "times", "timesnewroman",
        "timesnewromanpsmt", "courier", "couriernew", "menlo", "monaco", "geneva", "lucidagrande", "sfpro", "sfprotext",
        "sfprodisplay", "sfmono", "avenir", "avenirnext", "georgia", "verdana", "trebuchetms", "tahoma", "futura",
    ].map { $0.lowercased() }

    private struct Catalog {
        var aliases: [String: String] = [:]
        var faces: [String: Set<String>] = [:]
    }
    private static let catalog: Catalog = {
        var found = Catalog()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundled = Bundle.main.bundleURL.appendingPathComponent("../share/compositor/fonts").standardizedFileURL.path
        let checkout = FileManager.default.currentDirectoryPath + "/third_party/fonts/inter"
        let roots = [bundled, checkout, "/usr/share/fonts", "/usr/local/share/fonts", "/app/share/fonts", "/run/host/fonts",
                     "/run/host/user-fonts", "/run/host/local-fonts", "\(home)/.local/share/fonts", "\(home)/.fonts"]
        for root in roots {
            guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
            for case let relative as String in walker {
                let lower = relative.lowercased()
                guard lower.hasSuffix(".ttf") || lower.hasSuffix(".otf") || lower.hasSuffix(".ttc") || lower.hasSuffix(".otc") else { continue }
                guard let data = FileManager.default.contents(atPath: root + "/" + relative) else { continue }
                for face in fontFaces(in: data) {
                    guard let family = face.family else { continue }
                    for name in face.names { found.aliases[normalized(name)] = family }
                    if let name = face.postScript { found.faces[normalized(family), default: []].insert(name) }
                }
            }
        }
        return found
    }()

    /// Names (IDs 1 family, 4 full, 6 PostScript) of every face in a TrueType/OpenType file or collection.
    static func fontNames(in data: Data) -> [String] {
        fontFaces(in: data).flatMap(\.names)
    }

    private struct Face {
        var names: [String] = []
        var family: String?
        var postScript: String?
    }
    private static func fontFaces(in data: Data) -> [Face] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) << 8 | Int(bytes[o + 1]) : 0 }
        func u32(_ o: Int) -> Int { o + 3 < bytes.count ? u16(o) << 16 | u16(o + 2) : 0 }
        var faces: [Int] = [0]
        if bytes.count > 12, bytes[0] == 0x74, bytes[1] == 0x74, bytes[2] == 0x63, bytes[3] == 0x66 {   // "ttcf"
            let count = min(u32(8), 256)
            faces = (0..<count).map { u32(12 + 4 * $0) }
        }
        var result: [Face] = []
        for face in faces {
            var parsed = Face()
            var preferred: [Int: (rank: Int, text: String)] = [:]
            let tables = min(u16(face + 4), 512)
            for t in 0..<tables {
                let record = face + 12 + 16 * t
                guard record + 16 <= bytes.count, bytes[record..<record + 4].elementsEqual("name".utf8) else { continue }
                let table = u32(record + 8)
                let count = min(u16(table + 2), 2048), strings = table + u16(table + 4)
                for r in 0..<count {
                    let entry = table + 6 + 12 * r
                    let platform = u16(entry), nameID = u16(entry + 6)
                    guard [1, 4, 6, 16].contains(nameID) else { continue }
                    let length = u16(entry + 8), start = strings + u16(entry + 10)
                    guard start >= 0, length > 0, start + length <= bytes.count else { continue }
                    let raw = Data(bytes[start..<start + length])
                    let text = (platform == 0 || platform == 3) ? String(data: raw, encoding: .utf16BigEndian)
                                                               : String(data: raw, encoding: .macOSRoman)
                    if let text, !text.isEmpty {
                        parsed.names.append(text)
                        // Prefer English Unicode names while retaining every localized alias for lookup.
                        let rank = (platform == 3 || platform == 0 ? 2 : 0) + (u16(entry + 4) == 0x409 ? 1 : 0)
                        if preferred[nameID] == nil || rank > preferred[nameID]!.rank { preferred[nameID] = (rank, text) }
                    }
                }
            }
            parsed.family = preferred[16]?.text ?? preferred[1]?.text
            parsed.postScript = preferred[6]?.text
            result.append(parsed)
        }
        return result
    }
}
