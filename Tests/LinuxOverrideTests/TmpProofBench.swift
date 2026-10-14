import Foundation
import Testing
@testable import Compositor

@MainActor struct TmpProofBench {
    @Test func timeProof() throws {
        let e = UpstreamEditor()
        #expect(e.importRGBA([UInt8](repeating: 200, count: 16), width: 2, height: 2, name: "x", replacing: true) == 0)
        e.session.proofProfile = try #require(CMYK.installed().first)
        e.session.proofsColors = true
        for (w, h) in [(1400, 900), (4000, 3000)] {
            var bytes = (0..<(w * h * 4)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) | ($0 % 4 == 3 ? 255 : 0) }
            let start = Date()
            #expect(e.proofForDisplay(&bytes, width: w, height: h))
            print("TMPBENCH \(w)x\(h): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }
}
