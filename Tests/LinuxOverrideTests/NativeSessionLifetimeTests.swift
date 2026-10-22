import Foundation
import SwiftUI
import XCTest
@testable import Compositor

final class NativeSessionLifetimeTests: XCTestCase {
    func testClosingOneHandlePreservesAnotherHandlesNativeRows() throws {
        try MainActor.assumeIsolated {
            let first = compositorSessionCreate()
            let second = compositorSessionCreate()
            defer { compositorSessionClose(first); compositorSessionClose(second) }
            let entry = try XCTUnwrap(Sessions.entries[first])
            let other = Entry(editor: UpstreamEditor(session: entry.editor.session))
            Sessions.entries[second] = other
            let session = entry.editor.session
            session.createDocument(width: 64, height: 32, emptyLayer: true)
            let layer = try XCTUnwrap(session.activeLayerID)
            session.renameLayer(layer, to: "Shared document")
            XCTAssertNotEqual(entry.panelScope("LayersPanel"), other.panelScope("LayersPanel"))
            XCTAssertNotNil(resolvePanel("LayersPanel", entry: entry))
            XCTAssertNotNil(resolvePanel("LayersPanel", entry: other))
            compositorSessionClose(first)
            XCTAssertNotNil(session.document)
            XCTAssertTrue(entry.actionHandlers.isEmpty)
            session.renameLayer(layer, to: "Surviving handle")
            XCTAssertNotNil(resolvePanel("LayersPanel", entry: other))
            XCTAssertTrue(layerSnapshots(other).contains("Surviving handle"))
        }
    }

    func testClosedHandleRejectsLateObservationInvalidation() throws {
        try MainActor.assumeIsolated {
            let handle = compositorSessionCreate()
            defer { compositorSessionClose(handle) }
            let entry = try XCTUnwrap(Sessions.entries[handle])
            let key = DirtyPanels.Key(entry: entry.renderScopeID, panel: "LayersPanel")
            DirtyPanels.mark(key)
            XCTAssertEqual(DirtyPanels.take(entry), ["LayersPanel"])
            compositorSessionClose(handle)
            DirtyPanels.mark(key)
            XCTAssertTrue(DirtyPanels.take(entry).isEmpty)
        }
    }

    @MainActor private func layerSnapshots(_ entry: Entry) -> String {
        var result = ""
        for handlers in entry.actionHandlers["LayersPanel"]?.values ?? [:].values {
            if let snapshot = handlers["accessibilitySnapshot"] {
                let box = NativeAccessibilityBox()
                snapshot(box)
                result += String(decoding: box.data, as: UTF8.self)
            }
        }
        return result
    }

    @MainActor private final class WeakOwners {
        weak var entry: Entry?
        weak var session: EditorSession?
        init(_ entry: Entry) { self.entry = entry; session = entry.editor.session }
    }

    func testClosingALoweredPanelReleasesItsSession() async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        let owners = try await MainActor.run {
            let entry = try XCTUnwrap(Sessions.entries[handle])
            entry.editor.session.createDocument(width: 64, height: 32, emptyLayer: true)
            XCTAssertNotNil(resolvePanel("LayersPanel", entry: entry))
            return WeakOwners(entry)
        }
        await Task.detached { compositorSessionClose(handle) }.value
        // A canceled .task may hold its view until the executor resumes it. Yield to that executor before
        // checking lifetime; pumping Foundation's run loop inside a synchronous XCTest does not run Swift tasks.
        await Task.yield()
        await MainActor.run {
            XCTAssertNil(owners.entry, "The closed handle must release its bridge entry")
            XCTAssertNil(owners.session, "Lowered native views must not retain the closed editor session")
        }
    }

    func testReopenedLayerPanelsNeverUseAClosedSessionsCoordinator() throws {
        try MainActor.assumeIsolated {
            XCTAssertTrue(Thread.isMainThread)
            var scopes = Set<String>()
            defer {
                for scope in scopes {
                    ChangeTracker.discard(scope: scope)
                    StateStore.discard(scope: scope)
                    NativeLowering.discard(scope: scope)
                }
            }
            for index in 0..<32 {
                let handle = compositorSessionCreate()
                defer { compositorSessionClose(handle) }
                let entry = try XCTUnwrap(Sessions.entries[handle])
                let session = entry.editor.session
                session.createDocument(width: 64, height: 32, emptyLayer: true)
                let marker = "Panel owner \(index)"
                session.renameLayer(try XCTUnwrap(session.activeLayerID), to: marker)
                scopes.insert(entry.panelScope("LayersPanel"))
                XCTAssertNotNil(resolvePanel("LayersPanel", entry: entry))
                var snapshots = ""
                for handlers in entry.actionHandlers["LayersPanel"]?.values ?? [:].values {
                    if let snapshot = handlers["accessibilitySnapshot"] {
                        let box = NativeAccessibilityBox()
                        snapshot(box)
                        snapshots += String(decoding: box.data, as: UTF8.self)
                    }
                }
                XCTAssertTrue(snapshots.contains(marker), "A new handle's native rows must belong to its current session (\(index))")
            }
        }
    }
}
