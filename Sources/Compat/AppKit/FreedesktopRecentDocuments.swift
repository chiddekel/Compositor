import Foundation
import CLibXML2

/// The app's entry in the desktop's shared recent-file list. Keep other applications' metadata intact.
enum FreedesktopRecentDocuments {
    private static let bookmarkNamespace = "http://www.freedesktop.org/standards/desktop-bookmarks"
    private static let mimeNamespace = "http://www.freedesktop.org/standards/shared-mime-info"
    private static let applicationName = "Compositor"

    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = environment["XDG_DATA_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent(".local/share", isDirectory: true)
    }

    static func note(_ url: URL, in directory: URL) throws {
        guard url.isFileURL else { return }
        let file = directory.appendingPathComponent("recently-used.xbel")
        let document = try read(file)
        defer { xmlFreeDoc(document) }
        let root = xmlDocGetRootElement(document)!
        let href = url.standardizedFileURL.absoluteString
        let bookmark = try children(root, named: "bookmark").first { namespaceURI($0) == nil && attribute("href", on: $0) == href }
            ?? child("bookmark", in: root, reuse: false)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try attribute("href", href, on: bookmark)
        if attribute("added", on: bookmark) == nil { try attribute("added", stamp, on: bookmark) }
        try attribute("modified", stamp, on: bookmark)
        try attribute("visited", stamp, on: bookmark)
        let info = try child("info", in: bookmark)
        let metadata = try children(info, named: "metadata").first { namespaceURI($0) == nil && attribute("owner", on: $0) == "http://freedesktop.org" }
            ?? child("metadata", in: info, reuse: false)
        try attribute("owner", "http://freedesktop.org", on: metadata)
        let mimeNS = try namespace("mime", uri: mimeNamespace, in: document)
        let mime = try child("mime-type", in: metadata, namespace: mimeNS)
        let ext = url.pathExtension.lowercased()
        try attribute("type", ext == "comp" || ext == "compositor" ? "application/x-compositor-project" : "application/octet-stream", on: mime)
        let bookmarkNS = try namespace("bookmark", uri: bookmarkNamespace, in: document)
        let applications = try child("applications", in: metadata, namespace: bookmarkNS)
        let application = try children(applications, named: "application").first {
            namespaceURI($0) == bookmarkNamespace && attribute("name", on: $0) == applicationName
        }
            ?? child("application", in: applications, namespace: bookmarkNS, reuse: false)
        let count = max(0, Int(attribute("count", on: application) ?? "0") ?? 0)
        try attribute("name", applicationName, on: application)
        try attribute("exec", "compositor %u", on: application)
        try attribute("count", String(count == Int.max ? count : count + 1), on: application)
        try attribute("modified", stamp, on: application)
        try attribute("timestamp", String(Int(Date().timeIntervalSince1970)), on: application)
        try write(document, to: file)
    }

    static func clear(in directory: URL) throws {
        let file = directory.appendingPathComponent("recently-used.xbel")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let document = try read(file)
        defer { xmlFreeDoc(document) }
        var changed = false
        for bookmark in children(xmlDocGetRootElement(document)!, named: "bookmark") where namespaceURI(bookmark) == nil {
            var removedOurs = false, hasOtherApplications = false
            for info in children(bookmark, named: "info") where namespaceURI(info) == nil {
                for metadata in children(info, named: "metadata")
                    where namespaceURI(metadata) == nil && attribute("owner", on: metadata) == "http://freedesktop.org" {
                    for applications in children(metadata, named: "applications") where namespaceURI(applications) == bookmarkNamespace {
                        for application in children(applications, named: "application") {
                            guard namespaceURI(application) == bookmarkNamespace else { hasOtherApplications = true; continue }
                            if attribute("name", on: application) == applicationName {
                                xmlUnlinkNode(application); xmlFreeNode(application)
                                removedOurs = true
                            } else { hasOtherApplications = true }
                        }
                    }
                }
            }
            if removedOurs {
                changed = true
                if !hasOtherApplications { xmlUnlinkNode(bookmark); xmlFreeNode(bookmark) }
            }
        }
        if changed { try write(document, to: file) }
    }

    private static func read(_ file: URL) throws -> xmlDocPtr {
        let document: xmlDocPtr
        if FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            // XBEL needs no DTD; refuse entity declarations rather than resolving external data.
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  text.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
                  text.utf8.count < Int(Int32.max) else { throw CocoaError(.fileReadCorruptFile) }
            let options = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue)
            guard let parsed = text.withCString({ xmlReadMemory($0, Int32(text.utf8.count), nil, "UTF-8", options) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            document = parsed
        } else {
            guard let created = withXMLString("1.0", { xmlNewDoc($0) }) else { throw CocoaError(.fileWriteUnknown) }
            document = created
            do {
                guard let root = withXMLString("xbel", { xmlNewNode(nil, $0) }) else { throw CocoaError(.fileWriteUnknown) }
                xmlDocSetRootElement(document, root)
                try attribute("version", "1.0", on: root)
            } catch { xmlFreeDoc(document); throw error }
        }
        guard let root = xmlDocGetRootElement(document), name(root) == "xbel", namespaceURI(root) == nil else {
            xmlFreeDoc(document); throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    private static func write(_ document: xmlDocPtr, to file: URL) throws {
        var buffer: UnsafeMutablePointer<xmlChar>?, count: Int32 = 0
        xmlDocDumpFormatMemoryEnc(document, &buffer, &count, "UTF-8", 1)
        guard let buffer, count > 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { compositorXMLFree(buffer) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes: buffer, count: Int(count)).write(to: file, options: .atomic)
    }

    private static func attribute(_ key: String, on node: xmlNodePtr) -> String? {
        guard let value = withXMLString(key, { xmlGetProp(node, $0) }) else { return nil }
        defer { compositorXMLFree(value) }
        return String(decodingCString: value, as: UTF8.self)
    }

    private static func attribute(_ key: String, _ value: String, on node: xmlNodePtr) throws {
        let result = withXMLString(key) { key in withXMLString(value) { xmlSetProp(node, key, $0) } }
        guard result != nil else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func children(_ parent: xmlNodePtr, named key: String) -> [xmlNodePtr] {
        var result: [xmlNodePtr] = [], current = parent.pointee.children
        while let node = current {
            if node.pointee.type == XML_ELEMENT_NODE && name(node) == key { result.append(node) }
            current = node.pointee.next
        }
        return result
    }

    private static func name(_ node: xmlNodePtr) -> String {
        node.pointee.name.map { String(decodingCString: $0, as: UTF8.self) } ?? ""
    }

    private static func namespaceURI(_ node: xmlNodePtr) -> String? {
        node.pointee.ns?.pointee.href.map { String(decodingCString: $0, as: UTF8.self) }
    }

    private static func child(_ key: String, in parent: xmlNodePtr, namespace: xmlNsPtr? = nil, reuse: Bool = true) throws -> xmlNodePtr {
        let uri = namespace?.pointee.href.map { String(decodingCString: $0, as: UTF8.self) }
        if reuse, let found = children(parent, named: key).first(where: { namespaceURI($0) == uri }) { return found }
        guard let created = withXMLString(key, { xmlNewChild(parent, namespace, $0, nil) }) else { throw CocoaError(.fileWriteUnknown) }
        return created
    }

    private static func namespace(_ prefix: String, uri: String, in document: xmlDocPtr) throws -> xmlNsPtr {
        let root = xmlDocGetRootElement(document)!
        if let found = withXMLString(uri, { xmlSearchNsByHref(document, root, $0) }) { return found }
        var available = prefix, suffix = 1
        while withXMLString(available, { xmlSearchNs(document, root, $0) }) != nil {
            available = "\(prefix)\(suffix)"; suffix += 1
        }
        guard let created = withXMLString(uri, { uri in withXMLString(available) { xmlNewNs(root, uri, $0) } }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return created
    }

    private static func withXMLString<T>(_ value: String, _ body: (UnsafePointer<xmlChar>) -> T) -> T {
        value.utf8CString.withUnsafeBufferPointer { body(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: xmlChar.self)) }
    }
}
