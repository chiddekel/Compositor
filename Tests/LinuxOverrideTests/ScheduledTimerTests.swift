import Foundation
import Testing
@testable import Compositor

private final class TimerCapture {
    var deliveries = 0
}

@Suite(.serialized) @MainActor struct ScheduledTimerTests {
    @Test func scheduledOneShotFiresOnTheRunLoopAndReleasesItsWrapper() {
        var deliveries = 0
        weak var observed: MainActorTimer?
        do {
            let timer = MainActorTimer.scheduledTimer(withTimeInterval: 0.001, repeats: false) { timer in
                #expect(timer.isValid)
                #expect(timer === observed)
                deliveries += 1
            }
            observed = timer
        }
        #expect(observed != nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        #expect(deliveries == 1)
        #expect(observed == nil)
    }

    @Test func unscheduledTimerDoesNotRetainItsWrapper() {
        weak var observed: MainActorTimer?
        do {
            let timer = MainActorTimer(timeInterval: 60, repeats: true) { _ in }
            observed = timer
        }
        #expect(observed == nil)
    }

    @Test(arguments: [false, true])
    func canceledTimerReleasesItsWrapperAndCapturedObject(repeats: Bool) {
        weak var observed: MainActorTimer?
        weak var observedCapture: TimerCapture?
        var timer: MainActorTimer?
        do {
            let capture = TimerCapture()
            observedCapture = capture
            timer = MainActorTimer.scheduledTimer(withTimeInterval: 60, repeats: repeats) { _ in
                capture.deliveries += 1
            }
            observed = timer
        }
        #expect(observedCapture?.deliveries == 0)
        timer?.invalidate()
        // Foundation ignores an invalidated timer; the bridge must not retain it again.
        if let timer { RunLoop.current.add(timer, forMode: .default) }
        timer = nil
        #expect(observed == nil)
        #expect(observedCapture == nil)
    }

    @Test func repeatingTimerCanInvalidateItselfWithoutRetainingItsWrapper() {
        var deliveries = 0
        weak var observed: MainActorTimer?
        do {
            let timer = MainActorTimer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { timer in
                #expect(timer === observed)
                deliveries += 1
                timer.invalidate()
            }
            observed = timer
        }
        #expect(observed != nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        #expect(deliveries == 1)
        #expect(observed == nil)
    }

    @Test func manuallyScheduledTimerKeepsItsIdentityUntilDelivery() {
        var deliveries = 0
        weak var observed: MainActorTimer?
        do {
            let timer = MainActorTimer(timeInterval: 0.001, repeats: false) { timer in
                #expect(timer === observed)
                deliveries += 1
            }
            observed = timer
            RunLoop.current.add(timer, forMode: .default)
        }
        #expect(observed != nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        #expect(deliveries == 1)
        #expect(observed == nil)
    }
}
