import CoreGraphics
import SwiftUI
import XCTest

/// `.scrollPosition` and `.onScrollGeometryChange` (Export As's zoomed preview pans by dragging and keeps its middle
/// on zoom through them). Both used to do nothing: the scroll view never moved and the offset stayed at zero.
final class ScrollGeometryCompatTests: XCTestCase {
    private func scrollView(_ node: RenderNode) -> RenderNode? {
        if node.kind == "ScrollView" { return node }
        return node.children.lazy.compactMap(scrollView).first
    }

    func testScrollPositionIsShownAndFollowsTheUsersScrolling() throws {
        var position = ScrollPosition()
        position.scrollTo(point: CGPoint(x: 120, y: 45))
        let binding = Binding(get: { position }, set: { position = $0 })
        let view = ScrollView([.horizontal, .vertical]) { Color.clear.frame(width: 800, height: 600) }.scrollPosition(binding)
        let node = try XCTUnwrap(scrollView(ViewResolver.resolve(view)))
        XCTAssertEqual(node.boolParams["appKitScroll"], true, "the host reports this scroll view's geometry")
        XCTAssertEqual(node.doubleParams["scrollX"], 120)
        XCTAssertEqual(node.doubleParams["scrollY"], 45)
        let report = try XCTUnwrap(node.handlers["scrollGeometry"])
        report(["x": 300, "y": 10.5, "width": 200, "height": 150, "documentWidth": 800, "documentHeight": 600] as [String: Any])
        XCTAssertEqual(position.point, CGPoint(x: 300, y: 10.5))
    }

    func testGeometryChangeReportsOldAndNewValues() throws {
        var seen: [(CGPoint, CGPoint)] = []
        var position = ScrollPosition()
        let view = ScrollView([.horizontal, .vertical]) { Color.clear.frame(width: 800, height: 600) }
            .scrollPosition(Binding(get: { position }, set: { position = $0 }))
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { old, new in seen.append((old, new)) }
        let node = try XCTUnwrap(scrollView(ViewResolver.resolve(view)))
        let report = try XCTUnwrap(node.handlers["scrollGeometry"])
        report(["x": 40, "y": 30, "width": 200, "height": 150] as [String: Any])
        report(["x": 40, "y": 30, "width": 210, "height": 150] as [String: Any])   // resized, not scrolled: no change
        report(["x": 90, "y": 30, "width": 210, "height": 150] as [String: Any])
        XCTAssertEqual(seen.map(\.1), [CGPoint(x: 40, y: 30), CGPoint(x: 90, y: 30)])
        XCTAssertEqual(seen.map(\.0), [.zero, CGPoint(x: 40, y: 30)])
        XCTAssertEqual(position.point, CGPoint(x: 90, y: 30), "both modifiers hear the same report")
    }
}
