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
