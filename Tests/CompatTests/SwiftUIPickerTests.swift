import SwiftUI
import XCTest

final class SwiftUIPickerTests: XCTestCase {
    func testBooleanTagsUpdateSelectionInBothDirections() throws {
        var allLayers = false
        let picker = Picker("Sample", selection: Binding<Bool>(get: { allLayers }, set: { allLayers = $0 })) {
            Text("This Layer").tag(false)
            Text("All Layers").tag(true)
        }
        let node = ViewResolver.resolve(picker)
        let select = try XCTUnwrap(node.handlers["selection"])
        select("true")
        XCTAssertTrue(allLayers)
        XCTAssertEqual(ViewResolver.resolve(picker).stringParams["selection"], "true")
        select("false")
        XCTAssertFalse(allLayers)
        select("unknown")
        XCTAssertFalse(allLayers)
    }
}
