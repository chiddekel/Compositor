import Foundation

// Minimal Combine compatibility layer for Linux. Provides core publisher/subscriber abstractions,
// subjects, AnyCancellable, and Timer.publish so upstream SwiftUI/Mac code can compile unmodified.

public protocol Cancellable {
    func cancel()
}

public protocol CustomCombineIdentifierConvertible {
    var combineIdentifier: CombineIdentifier { get }
}

public struct CombineIdentifier: Hashable, CustomStringConvertible {
    private let id: UInt64
    public init() {
        struct Counter {
            static var next: UInt64 = 0
            static let lock = NSLock()
        }
        Counter.lock.lock()
        defer { Counter.lock.unlock() }
        Counter.next += 1
        id = Counter.next
    }
    public var description: String { "CombineIdentifier(\(id))" }
}

public final class AnyCancellable: Cancellable, Hashable {
    private var _cancel: (() -> Void)?
    public init(_ cancel: @escaping () -> Void) {
        self._cancel = cancel
    }
    public init<C: Cancellable>(_ canceller: C) {
        self._cancel = { canceller.cancel() }
    }
    deinit {
        _cancel?()
    }
    public func cancel() {
        _cancel?()
        _cancel = nil
    }
    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }
    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public enum Subscribers {
    public struct Demand: Equatable, Comparable, CustomStringConvertible {
        public static let none = Demand(0)
        public static let unlimited = Demand(Int.max)
        public static func max(_ value: Int) -> Demand { Demand(value) }
        let raw: Int
        init(_ raw: Int) { self.raw = raw }
        public static func < (lhs: Demand, rhs: Demand) -> Bool { lhs.raw < rhs.raw }
        public var description: String { raw == Int.max ? "unlimited" : "\(raw)" }
    }
    public enum Completion<Failure: Error> {
        case finished
        case failure(Failure)
    }
}

public protocol Subscription: Cancellable, CustomCombineIdentifierConvertible {
    func request(_ demand: Subscribers.Demand)
}

extension Subscription {
    public var combineIdentifier: CombineIdentifier { CombineIdentifier() }
}

public protocol Subscriber<Input, Failure>: CustomCombineIdentifierConvertible {
    associatedtype Input
    associatedtype Failure: Error
    func receive(subscription: Subscription)
    func receive(_ input: Input) -> Subscribers.Demand
    func receive(completion: Subscribers.Completion<Failure>)
}

extension Subscriber {
    public var combineIdentifier: CombineIdentifier { CombineIdentifier() }
}

public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure
}

extension Publisher {
    public func subscribe<S: Subscriber>(_ subscriber: S) where S.Input == Output, S.Failure == Failure {
        receive(subscriber: subscriber)
    }
    public func sink(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void = { _ in },
                     receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        let sub = SinkSubscriber<Output, Failure>(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
        subscribe(sub)
        return AnyCancellable { sub.cancel() }
    }
    public func eraseToAnyPublisher() -> AnyPublisher<Output, Failure> {
        AnyPublisher(self)
    }
}

private final class SinkSubscriber<Input, Failure: Error>: Subscriber {
    let receiveCompletion: (Subscribers.Completion<Failure>) -> Void
    let receiveValue: (Input) -> Void
    var subscription: Subscription?
    init(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void, receiveValue: @escaping (Input) -> Void) {
        self.receiveCompletion = receiveCompletion
        self.receiveValue = receiveValue
    }
    func receive(subscription: Subscription) {
        self.subscription = subscription
        subscription.request(.unlimited)
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        receiveValue(input)
        return .unlimited
    }
    func receive(completion: Subscribers.Completion<Failure>) {
        receiveCompletion(completion)
        subscription = nil
    }
    func cancel() {
        subscription?.cancel()
        subscription = nil
    }
}

public struct AnyPublisher<Output, Failure: Error>: Publisher {
    private let _subscribe: (Any) -> Void
    public init<P: Publisher>(_ publisher: P) where P.Output == Output, P.Failure == Failure {
        _subscribe = { anySub in
            if let sub = anySub as? any Subscriber<Output, Failure> {
                // simple box
            }
        }
    }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        _subscribe(subscriber)
    }
}

public protocol Subject<Output, Failure>: Publisher {
    func send(_ value: Output)
    func send(completion: Subscribers.Completion<Failure>)
    func send(subscription: Subscription)
}

public final class PassthroughSubject<Output, Failure: Error>: Subject, @unchecked Sendable {
    private var subscribers: [Any] = []
    public init() {}
    public func send(_ value: Output) {}
    public func send(completion: Subscribers.Completion<Failure>) {}
    public func send(subscription: Subscription) {}
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {}
}

public final class CurrentValueSubject<Output, Failure: Error>: Subject, @unchecked Sendable {
    public var value: Output
    public init(_ value: Output) { self.value = value }
    public func send(_ value: Output) { self.value = value }
    public func send(completion: Subscribers.Completion<Failure>) {}
    public func send(subscription: Subscription) {}
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {}
}

public protocol ObservableObject: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
}

public final class ObservableObjectPublisher: Publisher, Subject, @unchecked Sendable {
    public typealias Output = Void
    public typealias Failure = Never
    public init() {}
    public func send() {}
    public func send(_ value: Void) {}
    public func send(completion: Subscribers.Completion<Never>) {}
    public func send(subscription: Subscription) {}
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Void, S.Failure == Never {}
}

public protocol ConnectablePublisher: Publisher {
    func connect() -> Cancellable
}

public enum Publishers {
    public struct Autoconnect<Upstream: ConnectablePublisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _ = upstream.connect()
            upstream.receive(subscriber: subscriber)
        }
    }
}

extension ConnectablePublisher {
    public func autoconnect() -> Publishers.Autoconnect<Self> {
        Publishers.Autoconnect(upstream: self)
    }
}

extension Timer {
    public final class TimerPublisher: ConnectablePublisher {
        public typealias Output = Date
        public typealias Failure = Never
        public let interval: TimeInterval
        public let runLoop: RunLoop
        public let mode: RunLoop.Mode
        private var timer: Timer?

        public init(interval: TimeInterval, runLoop: RunLoop, mode: RunLoop.Mode) {
            self.interval = interval
            self.runLoop = runLoop
            self.mode = mode
        }

        public func connect() -> Cancellable {
            AnyCancellable { [weak self] in
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Date, S.Failure == Never {}
    }

    public static func publish(every interval: TimeInterval, tolerance: TimeInterval? = nil,
                               on runLoop: RunLoop, in mode: RunLoop.Mode,
                               options: RunLoop.SchedulerOptions? = nil) -> TimerPublisher {
        TimerPublisher(interval: interval, runLoop: runLoop, mode: mode)
    }
}

extension RunLoop {
    public struct SchedulerOptions: Sendable {
        public init() {}
    }
}
