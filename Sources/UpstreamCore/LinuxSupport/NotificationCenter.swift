// Part of the `Compositor` module but not upstream code (Sources/UpstreamCore/LinuxSupport is ours).
//
// Same gap as Timer.swift: Apple's `addObserver(forName:object:queue:using:)` lets a main-actor caller touch its own
// state from the block (Xcode's Swift 5 mode doesn't check the block against `Sendable`); swift-corelibs-foundation
// declares it `@Sendable`, which upstream's tab scroller (UI/ProjectTabs.swift, observing its clip view's bounds on
// `.main`) cannot satisfy under default main-actor isolation — and an extension overload can't win overload ranking
// against Foundation's. So, as with `Timer`, the name is shadowed in the module that uses it: this forwards to the
// real `Foundation.NotificationCenter.default` (posts from anywhere still arrive) and keeps Apple's block semantics.
// Only the members upstream uses exist (`default`, `addObserver(forName:object:queue:using:)`, `removeObserver`).

import Foundation

typealias NotificationCenter = MainActorNotificationCenter

final class MainActorNotificationCenter: @unchecked Sendable {
    static let `default` = MainActorNotificationCenter()
    private let center = Foundation.NotificationCenter.default
    /// Marks the main dispatch queue, which on Linux may be drained by a worker thread (`Thread.isMainThread` false).
    private static let mainQueueKey: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        DispatchQueue.main.setSpecific(key: key, value: true)
        return key
    }()

    @discardableResult
    func addObserver(forName name: NSNotification.Name?, object: Any?, queue: OperationQueue?,
                     using block: @escaping (Notification) -> Void) -> NSObjectProtocol {
        nonisolated(unsafe) let unchecked = block
        nonisolated(unsafe) let sender = object
        guard queue === OperationQueue.main else {
            return center.addObserver(forName: name, object: sender, queue: queue) { notification in unchecked(notification) }
        }
        // `queue: .main`: corelibs hands the block to OperationQueue.main and then waits for it, which deadlocks when
        // the post itself runs on the main queue. Like Apple's, deliver synchronously when already there and hop
        // to the main queue otherwise.
        let key = Self.mainQueueKey
        return center.addObserver(forName: name, object: sender, queue: nil) { notification in
            nonisolated(unsafe) let note = notification
            if DispatchQueue.getSpecific(key: key) == true { unchecked(note) }
            else { DispatchQueue.main.async { unchecked(note) } }
        }
    }
    func removeObserver(_ observer: Any) { center.removeObserver(observer) }
}
