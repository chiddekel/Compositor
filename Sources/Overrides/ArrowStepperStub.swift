// TEMP STAND-IN for `ArrowStepper`/`arrowSteps(editing:stepper:...)`, which are real upstream code living in
// Compositor/ContentView.swift (not wired in yet — ContentView.swift composes the whole Compositor/UI surface, out
// of scope while only a few panels are wired in). Remove this file once ContentView.swift joins the Linux build for
// real (see Sources/Compat/SwiftUI plan) — NavigationToolHeader.swift etc. then pick up the genuine upstream type.

import Foundation
import SwiftUI

@MainActor final class ArrowStepper {
    var editing = false
    var value: () -> Double = { 0 }
    var change: (Double) -> Void = { _ in }
    func listen(step: Double) {}
    func stopListening() {}
}

extension View {
    func arrowSteps(_ step: Double = 1, editing: Bool, stepper: ArrowStepper,
                    value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        onAppear { stepper.value = value; stepper.change = change }
    }
    /// The same, for a field that owns its own focus rather than sharing an external `ArrowStepper`.
    func arrowSteps(_ step: Double = 1, value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        self
    }
}
