import XCTest
import CoreGraphics
@testable import SwiftUI

final class ImageRegistryLeaseTests: XCTestCase {
    private func image() -> CGImage {
        CGImage(PortableImage(width: 1, height: 1, kind: .rgba, bytesPerRow: 4, bytes: [255, 0, 0, 255]))
    }

    func testLargeTimelinesSurviveUpdatesAndOtherWindowsThenRelease() throws {
        let scopes = ["ImageRegistryLeaseTests:first", "ImageRegistryLeaseTests:second"]
        defer { scopes.forEach { StateStore.discard(scope: $0) } }
        var views: [Image] = []
        var tokens: [[String]] = []
        for scope in scopes {
            // Construction can precede the render scope (as with a hosted root view).
            let window = (0..<4096).map { _ in Image(decorative: image(), scale: 1) }
            views += window
            XCTAssertTrue(StateStore.begin(scope: scope))
            tokens.append(window.map { String($0._makeNode(children: []).stringParams["source"]!.dropFirst(7)) })
            StateStore.end()
        }
        XCTAssertTrue(tokens.joined().allSatisfy { ImageRegistry.image(for: $0) != nil })
        XCTAssertTrue(StateStore.begin(scope: scopes[0]))
        let updated = views.prefix(4096).map { String($0._makeNode(children: []).stringParams["source"]!.dropFirst(7)) }
        StateStore.end()
        XCTAssertEqual(updated, tokens[0])
        XCTAssertTrue(tokens.joined().allSatisfy { ImageRegistry.image(for: $0) != nil })
        StateStore.discard(scope: scopes[0])
        // The unleased cache stays bounded; the other live window remains pinned.
        for _ in 0..<4096 { _ = ImageRegistry.token(for: image()) }
        XCTAssertTrue(tokens[0].allSatisfy { ImageRegistry.image(for: $0) == nil })
        XCTAssertTrue(tokens[1].allSatisfy { ImageRegistry.image(for: $0) != nil })
        StateStore.discard(scope: scopes[1])
        for _ in 0..<4096 { _ = ImageRegistry.token(for: image()) }
        XCTAssertTrue(tokens[1].allSatisfy { ImageRegistry.image(for: $0) == nil })
    }
}
