import Foundation

/// Runs an async operation from a synchronous context, blocking the caller
/// until the operation completes. Uses a detached Task so the operation
/// executes on the cooperative thread pool, not the waiting thread.
///
/// Only intended for the transport's request-handling thread, which already
/// serialises requests one at a time. Do NOT call from the main thread: the
/// detached Task may hop to MainActor internally, and parking the main
/// thread on the semaphore would deadlock.
func runBlocking<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) throws -> T {
    let holder = ResultHolder<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let value = try await operation()
            holder.set(.success(value))
        } catch {
            holder.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try holder.get().get()
}

/// Lock-guarded storage for the result of `runBlocking`'s detached Task.
/// Needed because Swift's strict concurrency forbids capturing a mutable
/// local from a `@Sendable` closure.
private final class ResultHolder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ v: Result<T, Error>) {
        lock.lock()
        value = v
        lock.unlock()
    }

    /// Precondition: caller has already waited on the signalling semaphore,
    /// so `value` is guaranteed to be set.
    func get() -> Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let value else {
            preconditionFailure(
                "ResultHolder accessed before the detached Task signalled completion"
            )
        }
        return value
    }
}
