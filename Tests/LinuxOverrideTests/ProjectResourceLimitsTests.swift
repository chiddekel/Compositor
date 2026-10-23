import Testing
@testable import Compositor

struct ProjectResourceLimitsTests {
    @Test func usesDocumentLimits() {
        #expect(compositorProjectMaxSurfacePixels() == DocumentLimits.maxSurfacePixels)
        #expect(compositorProjectPixelBudget() == DocumentLimits.documentPixelBudget)
        var used: Int64 = 0
        for _ in 0..<4 { used = compositorProjectAccountAsset(6000, 5000, Int(used)) }
        #expect(used == 120_000_000)
    }

    @Test func rejectsInvalidDimensionsAndOverflow() {
        for dimension in [Int.min, -1, 0, DocumentLimits.maxSide + 1, Int.max] {
            #expect(compositorProjectAccountAsset(dimension, 1, 0) == -1)
            #expect(compositorProjectAccountAsset(1, dimension, 0) == -1)
        }
        #expect(compositorProjectAccountAsset(DocumentLimits.maxSide, 1, 0) == Int64(DocumentLimits.maxSide))
        for used in [Int.min, -1, DocumentLimits.documentPixelBudget + 1, Int.max] {
            #expect(compositorProjectAccountAsset(1, 1, used) == -1)
        }
    }

    @Test func checksSurfaceAndCumulativeBoundaries() {
        #expect(compositorProjectAccountAsset(20_000, 9_999, 0) == 199_980_000)
        #expect(compositorProjectAccountAsset(20_000, 10_000, 0) == 200_000_000)
        #expect(compositorProjectAccountAsset(20_000, 10_001, 0) == -1)
        let limit = DocumentLimits.documentPixelBudget
        #expect(compositorProjectAccountAsset(1, 1, limit - 2) == Int64(limit - 1))
        #expect(compositorProjectAccountAsset(1, 1, limit - 1) == Int64(limit))
        #expect(compositorProjectAccountAsset(1, 1, limit) == -1)
    }
}
