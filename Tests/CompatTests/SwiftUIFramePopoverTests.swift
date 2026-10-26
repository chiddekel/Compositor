import Foundation
import SwiftUI
import XCTest

final class SwiftUIFramePopoverTests: XCTestCase {
    func testOptionalCGFloatFramesRetainAutomaticAndExplicitDimensions() throws {
        let width: CGFloat? = 57, height: CGFloat? = 22
        let fixed = ViewResolver.resolve(Text("Width").frame(width: width, height: height))
        guard case .frame(let w, let h, _, _, _, _, _) = try XCTUnwrap(fixed.modifiers.last) else {
            return XCTFail("Expected a frame modifier")
        }
        XCTAssertEqual(w, 57)
        XCTAssertEqual(h, 22)
        let automatic = ViewResolver.resolve(Text("Automatic").frame(width: CGFloat?.none))
        guard case .frame(let automaticWidth, _, _, _, _, _, _) = try XCTUnwrap(automatic.modifiers.last) else {
            return XCTFail("Expected an automatic frame modifier")
        }
        XCTAssertNil(automaticWidth)
    }

    func testPopoverRetainsArrowPreferenceAndDismissesItsBinding() throws {
        var presented = true
        let binding = Binding<Bool>(get: { presented }, set: { presented = $0 })
        let node = ViewResolver.resolve(Text("Align").popover(isPresented: binding, arrowEdge: .bottom) {
            Text("Align controls")
        })
        XCTAssertEqual(node.kind, "Popover")
        XCTAssertEqual(node.stringParams["arrowEdge"], "bottom")
        XCTAssertEqual(node.children.count, 2)
        try XCTUnwrap(node.handlers["dismiss"])(())
        XCTAssertFalse(presented)
        let defaultNode = ViewResolver.resolve(Text("Crop").popover(isPresented: .constant(true)) { Text("Ratio") })
        XCTAssertNil(defaultNode.stringParams["arrowEdge"])
    }
}
