import Dispatch

// Synchronous C APIs may wait for Swift actors. Match the Qt host's native
// workers instead of blocking the cooperative executor that those actors need.
func onNativeWorker<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: operation())
        }
    }
}

func onNativeWorker<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result(catching: operation))
        }
    }
}
