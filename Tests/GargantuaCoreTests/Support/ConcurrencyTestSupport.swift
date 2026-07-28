import Foundation

/// Drains one pending signal if there is one, without ever blocking.
///
/// `DispatchSemaphore.wait(timeout:)` is `noasync` like its untimed sibling,
/// but `noasync` is enforced at the call site — a synchronous function may
/// still call it. A `.now()` deadline cannot block, so this is safe to reach
/// from a task.
private func drainSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

/// Awaits a `DispatchSemaphore` signal from an async context.
///
/// Polls rather than parking a global-queue worker on a blocking `wait()`, so
/// no thread is held for the duration and a cancelled task stops waiting
/// instead of hanging. Cancellation returns without the signal — callers are
/// tests whose expectations then fail loudly rather than time out.
func awaitSignal(_ semaphore: DispatchSemaphore) async {
    while !drainSignal(semaphore) {
        if Task.isCancelled { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// A thread-safe counter for asserting how many times a test double was called.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

/// Carries a value across a concurrency boundary in tests, where the compiler
/// cannot prove `T` is `Sendable` but the lock makes access safe.
final class UncheckedSendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
