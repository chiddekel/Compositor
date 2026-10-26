// Part of the `Compositor` module but not upstream code (Sources/UpstreamCore/LinuxSupport is ours).
//
// Apple's `Timer(timeInterval:repeats:block:)` lets a timer created by a main-actor object touch that object's state
// from the block. swift-corelibs-foundation declares the block `@Sendable`, which upstream's marching-ants timer
// (Rendering/EditorCanvas.swift) cannot satisfy under Xcode's default main-actor isolation. Declaring `Timer` in the
// module that uses it shadows Foundation's type for upstream code; this wrapper keeps Apple's block semantics and
// forwards to a real Foundation timer. Only the members upstream uses exist (`init(timeInterval:repeats:block:)`,
// `scheduledTimer`, `invalidate()`, and `RunLoop.add`).

import Foundation
import Combine

typealias Timer = MainActorTimer

final class MainActorTimer {
    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private weak var owner: MainActorTimer?
        private var scheduledOwner: MainActorTimer?
        private var block: ((MainActorTimer) -> Void)?

        init(_ block: @escaping (MainActorTimer) -> Void) { self.block = block }

        func connect(_ timer: MainActorTimer) {
            lock.lock(); owner = timer; lock.unlock()
        }

        func keepScheduled(_ timer: MainActorTimer) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard block != nil else { return false }
            scheduledOwner = timer
            return true
        }

        func deliver(_ native: Foundation.Timer) {
            lock.lock()
            let timer = owner, action = block
            lock.unlock()
            guard let timer, let action else { return }
            defer { if native.timeInterval <= 0 || !native.isValid { cancel() } }
            action(timer)
        }

        func cancel() {
            lock.lock()
            let retained = (scheduledOwner, block)
            scheduledOwner = nil; block = nil
            lock.unlock()
            // Releasing a callback capture may run user code, including another invalidation.
            withExtendedLifetime(retained) {}
        }
    }

    let inner: Foundation.Timer
    private let delivery: Delivery

    init(timeInterval interval: TimeInterval, repeats: Bool, block: @escaping (MainActorTimer) -> Void) {
        let delivery = Delivery(block)
        self.delivery = delivery
        inner = Foundation.Timer(fire: Date().addingTimeInterval(interval), interval: repeats ? interval : 0,
                                 repeats: repeats, block: { delivery.deliver($0) })
        delivery.connect(self)
    }
    func invalidate() {
        inner.invalidate()
        delivery.cancel()
    }
    var isValid: Bool { inner.isValid }

    fileprivate func prepareForScheduling() -> Bool {
        inner.isValid && delivery.keepScheduled(self)
    }

    @discardableResult
    static func scheduledTimer(withTimeInterval interval: TimeInterval, repeats: Bool,
                               block: @escaping (MainActorTimer) -> Void) -> MainActorTimer {
        let timer = MainActorTimer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.current.add(timer, forMode: .default)
        return timer
    }
}

extension RunLoop {
    func add(_ timer: MainActorTimer, forMode mode: RunLoop.Mode) {
        guard timer.prepareForScheduling() else { return }
        add(timer.inner, forMode: mode)
    }
}

// `Timer` (unqualified, in this module) resolves to `MainActorTimer` per the shadowing `typealias` above, so
// `Compositor/UI/ProjectTabs.swift`'s `Timer.publish(every:on:in:).autoconnect()` needs its own `.publish`, distinct
// from `Combine.swift`'s extension on the real `Foundation.Timer` (which nothing in this module ever sees).
extension MainActorTimer {
    struct TimerPublisher: CombinePublisher {
        typealias Output = Date
        func autoconnect() -> TimerPublisher { self }
    }
    static func publish(every interval: Double, on runLoop: RunLoop, in mode: RunLoop.Mode) -> TimerPublisher {
        TimerPublisher()
    }
}
