import XCTest
import Foundation
import CLibXML2
@testable import AppKit

final class FreedesktopRecentDocumentsTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recent-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func bookmarks(_ directory: URL) throws -> [RecentXMLNode] {
        let document = try RecentXMLDocument(contentsOf: directory.appendingPathComponent("recently-used.xbel"))
        return try XCTUnwrap(document.rootElement()).elements(forName: "bookmark").filter { $0.namespaceURI == nil }
    }

    private func applications(_ bookmark: RecentXMLNode) throws -> [RecentXMLNode] {
        try bookmark.nodes(forXPath: "info/metadata/*[local-name()='applications']/*[local-name()='application']")
    }

    func testDataDirectoryHonorsAbsoluteXDGAndFallsBackForRelativePaths() {
        let home = URL(fileURLWithPath: "/tmp/recent-home", isDirectory: true)
        XCTAssertEqual(FreedesktopRecentDocuments.dataDirectory(environment: ["XDG_DATA_HOME": "/tmp/recent-data"], home: home).path,
                       "/tmp/recent-data")
        for environment in [[:], ["XDG_DATA_HOME": ""], ["XDG_DATA_HOME": "relative/data"]] {
            XCTAssertEqual(FreedesktopRecentDocuments.dataDirectory(environment: environment, home: home).path,
                           "/tmp/recent-home/.local/share")
        }
    }

    func testEscapedUnicodeURLAndRepeatedOpenRemainValidAndUnique() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("A&B \"żółć\".comp")
            try FreedesktopRecentDocuments.note(url, in: directory)
            try FreedesktopRecentDocuments.note(url, in: directory)
            let entries = try bookmarks(directory)
            XCTAssertEqual(entries.count, 1)
            let bookmark = try XCTUnwrap(entries.first)
            XCTAssertEqual(bookmark.attribute(forName: "href")?.stringValue, url.standardizedFileURL.absoluteString)
            let apps = try applications(bookmark)
            XCTAssertEqual(apps.count, 1)
            XCTAssertEqual(apps.first?.attribute(forName: "name")?.stringValue, "Compositor")
            XCTAssertEqual(apps.first?.attribute(forName: "count")?.stringValue, "2")
            let mime = try bookmark.nodes(forXPath: "info/metadata/*[local-name()='mime-type']").first
            XCTAssertEqual(mime?.attribute(forName: "type")?.stringValue, "application/x-compositor-project")
        }
    }

    func testExistingOtherApplicationAndMetadataSurviveOpen() throws {
        try withDirectory { directory in
            let url = URL(fileURLWithPath: "/tmp/shared.comp")
            let fixture = """
            <xbel version="1.0" xmlns:b="http://www.freedesktop.org/standards/desktop-bookmarks">
              <bookmark href="\(url.absoluteString)" added="2020-01-01T00:00:00Z">
                <title>Shared &amp; named</title>
                <info><metadata owner="http://freedesktop.org">
                  <b:applications><b:application name="Other Editor" count="7" exec="other %u"/></b:applications>
                  <b:groups><b:group>Graphics</b:group></b:groups>
                </metadata><metadata owner="other"><custom>preserve</custom></metadata></info>
              </bookmark>
            </xbel>
            """
            try fixture.write(to: directory.appendingPathComponent("recently-used.xbel"), atomically: true, encoding: .utf8)
            try FreedesktopRecentDocuments.note(url, in: directory)
            let entries = try bookmarks(directory)
            XCTAssertEqual(entries.count, 1)
            let bookmark = try XCTUnwrap(entries.first)
            XCTAssertEqual(bookmark.attribute(forName: "added")?.stringValue, "2020-01-01T00:00:00Z")
            XCTAssertEqual(bookmark.elements(forName: "title").first?.stringValue, "Shared & named")
            let apps = try applications(bookmark)
            XCTAssertEqual(apps.count, 2)
            XCTAssertEqual(apps.first { $0.attribute(forName: "name")?.stringValue == "Other Editor" }?.attribute(forName: "count")?.stringValue, "7")
            XCTAssertEqual(try bookmark.nodes(forXPath: "info/metadata[@owner='other']/custom").first?.stringValue, "preserve")
            XCTAssertEqual(try bookmark.nodes(forXPath: "info/metadata/*[local-name()='groups']/*").first?.stringValue, "Graphics")
        }
    }

    func testClearRemovesOnlyCompositorApplicationsAndSolelyOwnedBookmarks() throws {
        try withDirectory { directory in
            let fixture = """
            <xbel version="1.0" xmlns:b="http://www.freedesktop.org/standards/desktop-bookmarks">
              <bookmark href="file:///tmp/shared.comp"><info><metadata owner="http://freedesktop.org">
                <b:applications><b:application name="Other Editor" count="7"/><b:application name="Compositor" count="2"/></b:applications>
              </metadata></info></bookmark>
              <bookmark href="file:///tmp/ours.comp"><info><metadata owner="http://freedesktop.org">
                <b:applications><b:application name="Compositor" count="1"/></b:applications>
              </metadata></info></bookmark>
              <bookmark href="file:///tmp/unrelated.png"><info><metadata owner="http://freedesktop.org">
                <b:applications><b:application name="Other Editor" count="3"/></b:applications>
              </metadata></info></bookmark>
            </xbel>
            """
            let file = directory.appendingPathComponent("recently-used.xbel")
            try fixture.write(to: file, atomically: true, encoding: .utf8)
            try FreedesktopRecentDocuments.clear(in: directory)
            let entries = try bookmarks(directory)
            XCTAssertEqual(entries.map { $0.attribute(forName: "href")?.stringValue }, ["file:///tmp/shared.comp", "file:///tmp/unrelated.png"])
            XCTAssertEqual(try applications(entries[0]).map { $0.attribute(forName: "name")?.stringValue }, ["Other Editor"])
            XCTAssertEqual(try applications(entries[0]).first?.attribute(forName: "count")?.stringValue, "7")
            let once = try Data(contentsOf: file)
            try FreedesktopRecentDocuments.clear(in: directory)
            XCTAssertEqual(try Data(contentsOf: file), once)
        }
    }

    func testMalformedAndEntityBearingFilesAreNotOverwritten() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("recently-used.xbel")
            for fixture in ["<xbel><bookmark></xbel>", "<wrong/>", "<x:xbel xmlns:x='urn:other'/>",
                            "<!DOCTYPE xbel [<!ENTITY external SYSTEM 'file:///tmp/never-read'>]><xbel/>"] {
                try fixture.write(to: file, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try FreedesktopRecentDocuments.note(URL(fileURLWithPath: "/tmp/new.comp"), in: directory))
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), fixture)
                XCTAssertThrowsError(try FreedesktopRecentDocuments.clear(in: directory))
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), fixture)
            }
        }
    }

    func testForeignApplicationNamespaceAndOccupiedPrefixRemainIntact() throws {
        try withDirectory { directory in
            let uri = "http://www.freedesktop.org/standards/desktop-bookmarks"
            let url = URL(fileURLWithPath: "/tmp/namespaced.comp")
            let fixture = """
            <xbel version="1.0" xmlns:b="\(uri)" xmlns:x="urn:other" xmlns:mime="urn:foreign-mime">
              <x:bookmark href="\(url.absoluteString)"><x:marker>foreign bookmark</x:marker></x:bookmark>
              <bookmark href="\(url.absoluteString)"><info><metadata owner="http://freedesktop.org">
                <b:applications><x:application name="Compositor" count="99"/></b:applications>
                <mime:marker>preserve</mime:marker>
              </metadata></info></bookmark>
            </xbel>
            """
            try fixture.write(to: directory.appendingPathComponent("recently-used.xbel"), atomically: true, encoding: .utf8)
            try FreedesktopRecentDocuments.note(url, in: directory)
            let bookmark = try XCTUnwrap(try bookmarks(directory).first)
            let apps = try applications(bookmark)
            XCTAssertEqual(apps.count, 2)
            XCTAssertEqual(apps.first { $0.namespaceURI == uri }?.attribute(forName: "count")?.stringValue, "1")
            XCTAssertEqual(apps.first { $0.namespaceURI == "urn:other" }?.attribute(forName: "count")?.stringValue, "99")
            XCTAssertEqual(try bookmark.nodes(forXPath: "info/metadata/*[local-name()='marker']").first?.namespaceURI, "urn:foreign-mime")
            try FreedesktopRecentDocuments.clear(in: directory)
            let remaining = try XCTUnwrap(try bookmarks(directory).first)
            let remainingApps = try applications(remaining)
            XCTAssertEqual(remainingApps.count, 1)
            XCTAssertEqual(remainingApps.first?.namespaceURI, "urn:other")
            XCTAssertEqual(remainingApps.first?.attribute(forName: "count")?.stringValue, "99")
            XCTAssertEqual(try remaining.nodes(forXPath: "info/metadata/*[local-name()='marker']").first?.stringValue, "preserve")
            let root = try XCTUnwrap(try RecentXMLDocument(contentsOf: directory.appendingPathComponent("recently-used.xbel")).rootElement())
            XCTAssertEqual(try root.nodes(forXPath: "*[local-name()='bookmark' and namespace-uri()='urn:other']/*").first?.stringValue,
                           "foreign bookmark")
        }
    }

    func testNonFileURLsAndClearingAnAbsentListCreateNothing() throws {
        try withDirectory { directory in
            try FreedesktopRecentDocuments.note(try XCTUnwrap(URL(string: "https://example.invalid/project")), in: directory)
            try FreedesktopRecentDocuments.clear(in: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recently-used.xbel").path))
        }
    }
}

/// Inspect saved XML through XPath, independently of the writer's tree traversal.
private final class RecentXMLDocument {
    let pointer: xmlDocPtr
    init(contentsOf url: URL) throws {
        guard let document = xmlReadFile(url.path, nil, Int32(XML_PARSE_NONET.rawValue)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pointer = document
    }
    deinit { xmlFreeDoc(pointer) }
    func rootElement() -> RecentXMLNode? {
        xmlDocGetRootElement(pointer).map { RecentXMLNode($0, owner: self) }
    }
}

private struct RecentXMLAttribute { let stringValue: String }

private final class RecentXMLNode {
    let pointer: xmlNodePtr
    let owner: RecentXMLDocument
    init(_ pointer: xmlNodePtr, owner: RecentXMLDocument) { self.pointer = pointer; self.owner = owner }
    var namespaceURI: String? {
        pointer.pointee.ns?.pointee.href.map { String(decodingCString: $0, as: UTF8.self) }
    }
    var stringValue: String? {
        guard let text = xmlNodeGetContent(pointer) else { return nil }
        defer { compositorXMLFree(text) }
        return String(decodingCString: text, as: UTF8.self)
    }
    func attribute(forName key: String) -> RecentXMLAttribute? {
        let value = key.utf8CString.withUnsafeBufferPointer {
            xmlGetProp(pointer, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: xmlChar.self))
        }
        guard let value else { return nil }
        defer { compositorXMLFree(value) }
        return RecentXMLAttribute(stringValue: String(decodingCString: value, as: UTF8.self))
    }
    func elements(forName key: String) -> [RecentXMLNode] {
        var result: [RecentXMLNode] = [], current = pointer.pointee.children
        while let node = current {
            if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name,
               String(decodingCString: name, as: UTF8.self) == key { result.append(RecentXMLNode(node, owner: owner)) }
            current = node.pointee.next
        }
        return result
    }
    func nodes(forXPath path: String) throws -> [RecentXMLNode] {
        guard let context = xmlXPathNewContext(owner.pointer) else { throw CocoaError(.fileReadUnknown) }
        defer { xmlXPathFreeContext(context) }
        context.pointee.node = pointer
        let object = path.utf8CString.withUnsafeBufferPointer {
            xmlXPathEvalExpression(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: xmlChar.self), context)
        }
        guard let object else { throw CocoaError(.fileReadCorruptFile) }
        defer { xmlXPathFreeObject(object) }
        guard let nodes = object.pointee.nodesetval, let array = nodes.pointee.nodeTab else { return [] }
        return (0..<Int(nodes.pointee.nodeNr)).compactMap {
            array[$0].map { RecentXMLNode($0, owner: owner) }
        }
    }
}
