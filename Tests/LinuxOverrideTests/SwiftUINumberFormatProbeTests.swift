import SwiftUI
import Testing

struct SwiftUINumberFormatProbeTests {
    @Test func numericTextFieldSerializesFractionLengthPrecision() {
        let value = Binding<Double>(get: { 1.2 }, set: { _ in })
        let field = TextField("Value", value: value, format: .number.precision(.fractionLength(2...3)))
        let node = ViewResolver.resolve(field)

        #expect(node.doubleParams["minimumFractionLength"] == 2)
        #expect(node.doubleParams["maximumFractionLength"] == 3)
    }

    @Test func percentTextUsesConfiguredFractionLengthPrecision() {
        let format = FloatingPointFormatStyle<Double>.percent.precision(.fractionLength(0...1))
        let node = ViewResolver.resolve(Text(0.125, format: format))

        // The user's locale decides the separator, as SwiftUI's does ("12.5%" in English, "12,5%" in Polish); the
        // precision is what this checks: one fraction digit, no trailing zeros dropped into two.
        let text = node.stringParams["text"] ?? ""
        #expect(text == "12.5%" || text == "12,5%")
    }
}
