import Testing
import Foundation
@testable import AppKit

@Suite struct RecentDocumentsLinuxTests {
    @MainActor @Test func notesProjectIntoFreedesktopRecentlyUsed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositor-recent-\(UUID().uuidString).comp")
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8)))
        defer { try? FileManager.default.removeItem(at: url) }

        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        let xbel = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/recently-used.xbel")
        let text = try String(contentsOf: xbel, encoding: .utf8)
        #expect(text.contains(url.lastPathComponent), "expected bookmark for \(url.lastPathComponent)")
        #expect(NSDocumentController.shared.recentDocumentURLs.contains { $0.path == url.path })
    }
}
