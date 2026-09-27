import XCTest
import FoundationCompat
import CSQLite

final class SQLiteUserDefaultsTests: XCTestCase {
    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preferences-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("preferences.sqlite3"))
    }

    func testExistingPreferenceTypesSurviveReopening() throws {
        try withDatabase { url in
            let defaults = SQLiteUserDefaults(databaseURL: url)
            defaults.set(["/tmp/żółć.comp", "/tmp/two.comp"], forKey: "NSRecentDocumentURLs")
            defaults.set(true, forKey: "tool.enabled")
            defaults.set(false, forKey: "false")
            defaults.set(0, forKey: "zero")
            defaults.set(1, forKey: "one")
            defaults.set(280.5, forKey: "layersPanelWidth")
            defaults.set(Data([0, 1, 255]), forKey: "keyboardShortcuts.v1")
            defaults.set(Data(), forKey: "emptyData")
            defaults.set([String](), forKey: "emptyArray")
            defaults.set("", forKey: "emptyString")
            defaults.set(["enabled": true, "name": "test"], forKey: "dictionary")
            XCTAssertTrue(defaults.synchronize())
            let reopened = SQLiteUserDefaults(databaseURL: url)
            XCTAssertEqual(reopened.stringArray(forKey: "NSRecentDocumentURLs"), ["/tmp/żółć.comp", "/tmp/two.comp"])
            XCTAssertEqual(reopened.object(forKey: "tool.enabled") as? Bool, true)
            XCTAssertEqual(reopened.object(forKey: "false") as? Bool, false)
            XCTAssertEqual(reopened.object(forKey: "zero") as? Int, 0)
            XCTAssertEqual(reopened.object(forKey: "one") as? Int, 1)
            XCTAssertEqual(reopened.object(forKey: "layersPanelWidth") as? Double, 280.5)
            XCTAssertEqual(reopened.data(forKey: "keyboardShortcuts.v1"), Data([0, 1, 255]))
            XCTAssertEqual(reopened.data(forKey: "emptyData"), Data())
            XCTAssertEqual(reopened.stringArray(forKey: "emptyArray"), [])
            XCTAssertEqual(reopened.string(forKey: "emptyString"), "")
            XCTAssertEqual((reopened.object(forKey: "dictionary") as? [String: Any])?["enabled"] as? Bool, true)
        }
    }

    func testMigrationIsOnceOnlyIncludingDeletedValues() throws {
        try withDatabase { url in
            let defaults = SQLiteUserDefaults(databaseURL: url) { ["old": "value", "width": 120.5] }
            XCTAssertEqual(defaults.string(forKey: "old"), "value")
            defaults.removeObject(forKey: "old")
            defaults.set(300.0, forKey: "width")
            let reopened = SQLiteUserDefaults(databaseURL: url) {
                XCTFail("Legacy preferences must not be imported again")
                return ["old": "value", "width": 120.5]
            }
            XCTAssertNil(reopened.object(forKey: "old"))
            XCTAssertEqual(reopened.double(forKey: "width"), 300)
        }
    }

    func testUnavailableDirectoryRetainsChangesAndCanRecover() throws {
        try withDatabase { url in
            let directory = url.deletingLastPathComponent()
            try Data("blocking file".utf8).write(to: directory)
            let defaults = SQLiteUserDefaults(databaseURL: url)
            defaults.set(["/tmp/project.comp"], forKey: "NSRecentDocumentURLs")
            XCTAssertFalse(defaults.synchronize())
            XCTAssertEqual(defaults.stringArray(forKey: "NSRecentDocumentURLs"), ["/tmp/project.comp"])
            try FileManager.default.removeItem(at: directory)
            XCTAssertTrue(defaults.synchronize())
            XCTAssertEqual(SQLiteUserDefaults(databaseURL: url).stringArray(forKey: "NSRecentDocumentURLs"), ["/tmp/project.comp"])
        }
    }

    func testLockedDatabaseRetriesPendingWritesWithoutLosingOtherKeys() throws {
        try withDatabase { url in
            let defaults = SQLiteUserDefaults(databaseURL: url)
            defaults.set("original", forKey: "keep")
            defaults.set("remove", forKey: "delete")
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
            defer { sqlite3_close(connection) }
            XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
            defaults.set("pending", forKey: "new")
            defaults.removeObject(forKey: "delete")
            XCTAssertFalse(defaults.synchronize())
            XCTAssertEqual(defaults.string(forKey: "new"), "pending")
            XCTAssertEqual(sqlite3_exec(connection, "COMMIT", nil, nil, nil), SQLITE_OK)
            XCTAssertTrue(defaults.synchronize())
            let reopened = SQLiteUserDefaults(databaseURL: url)
            XCTAssertEqual(reopened.string(forKey: "keep"), "original")
            XCTAssertEqual(reopened.string(forKey: "new"), "pending")
            XCTAssertNil(reopened.object(forKey: "delete"))
        }
    }

    func testConcurrentWritesRemainReadable() throws {
        try withDatabase { url in
            let defaults = SQLiteUserDefaults(databaseURL: url)
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                defaults.set(["\(index).comp"], forKey: "recent.\(index)")
            }
            let reopened = SQLiteUserDefaults(databaseURL: url)
            for index in 0..<40 {
                XCTAssertEqual(reopened.stringArray(forKey: "recent.\(index)"), ["\(index).comp"])
            }
        }
    }
}
