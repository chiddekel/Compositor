import SwiftUI
import Testing

struct SwiftUIImageProbeTests {
    @Test func imageScalingOptionsReachTheRenderNode() {
        let fit = ViewResolver.resolve(Image(systemName: "photo").resizable().scaledToFit())
        #expect(fit.boolParams["resizable"] == true)
        #expect(fit.stringParams["contentMode"] == "fit")

        let fill = ViewResolver.resolve(Image(systemName: "photo").resizable().scaledToFill())
        #expect(fill.stringParams["contentMode"] == "fill")

        let ratio = ViewResolver.resolve(Image(systemName: "photo").resizable().aspectRatio(1.5, contentMode: .fit))
        #expect(ratio.doubleParams["aspectRatio"] == 1.5)
        #expect(ratio.stringParams["contentMode"] == "fit")
    }
}
