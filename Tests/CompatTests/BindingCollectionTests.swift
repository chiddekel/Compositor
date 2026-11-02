import XCTest
import SwiftUI

final class BindingCollectionTests: XCTestCase {
    func testElementBindingPreservesOtherEditsAndCollectionIndices() {
        var values = [10, 20, 30][1...]
        let collection = Binding(get: { values }, set: { values = $0 })
        let element = collection[2]
        values[1] = 99
        element.wrappedValue = 42
        XCTAssertEqual(Array(values), [99, 42])
        values[2] = 77
        XCTAssertEqual(element.wrappedValue, 77)
    }
}
