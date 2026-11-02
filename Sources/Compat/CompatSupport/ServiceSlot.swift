// ServiceSlot.swift — how every compat module exposes a replaceable service (dependency inversion made explicit).
//
// The compat layer imitates Apple frameworks, so the code that calls it (upstream's unmodified sources) cannot take a
// service through an initialiser. Each module instead keeps its seam in a `ServiceSlot`: the host installs an
// implementation once at start-up, code under test swaps one for the duration of a closure, and nobody reaches for a
// bare mutable global. The slot holds only the interface type; it knows nothing about Skia, Qt or Vulkan.
//
// Members are nonisolated: the lock makes the slot safe from any thread (timers, observation, host C hooks).

import Foundation

public final class ServiceSlot<Value>: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var installed: Value?
    nonisolated(unsafe) private let fallback: () -> Value?

    /// `fallback` supplies the built-in implementation when nothing has been installed (nil for "no service").
    nonisolated public init(fallback: @escaping () -> Value? = { nil }) { self.fallback = fallback }

    /// The installed service, or the fallback.
    nonisolated public var current: Value? {
        lock.lock(); defer { lock.unlock() }
        return installed ?? fallback()
    }

    /// The service the host installed, without the fallback.
    nonisolated public var installedValue: Value? {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    /// Installs `value` (nil removes it, restoring the fallback).
    nonisolated public func install(_ value: Value?) {
        lock.lock(); installed = value; lock.unlock()
    }

    /// Runs `body` with `value` installed and puts the previous service back afterwards. Serialises callers that
    /// override the same slot; not meant for tests that run the same slot in parallel.
    nonisolated public func withOverride<Result>(_ value: Value?, _ body: () throws -> Result) rethrows -> Result {
        lock.lock(); let previous = installed; installed = value; lock.unlock()
        defer { lock.lock(); installed = previous; lock.unlock() }
        return try body()
    }
}
