import SwiftUI
import Testing

struct SwiftUIShapeInsetProbeTests {
    @Test func insetMovesRoundedShapeBoundsAndSerializesItsGeometry() {
        let insetShape = RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: 1)
        let path = insetShape.path(in: CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(path.cgPath.boundingBox.minX == 1)
        #expect(path.cgPath.boundingBox.minY == 1)
        #expect(path.cgPath.boundingBox.width == 18)
        #expect(path.cgPath.boundingBox.height == 8)

        let node = ViewResolver.resolve(insetShape.strokeBorder(.white, lineWidth: 1))
        #expect(node.stringParams["shapeKind"] == "roundedRectangle")
        #expect(node.doubleParams["inset"] == 1)
    }
}
