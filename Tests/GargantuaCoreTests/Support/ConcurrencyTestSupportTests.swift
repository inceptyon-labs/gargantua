import Foundation
import Testing

/// Consumes a pending signal if there is one. Declared here rather than reusing
/// the helper under test so these assertions do not depend on it, and
/// synchronous because `wait(timeout:)` is `noasync` at the call site.
private func consumedSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

/// Set from a task, read from the test body.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() { lock.withLock { completed = true } }
    var isCompleted: Bool { lock.withLock { completed } }
}

@Suite("awaitSignal")
struct ConcurrencyTestSupportTests {

    @Test("a signal already pending is consumed")
    func consumesPendingSignal() async {
        // Signalled up from zero rather than created at one: libdispatch traps
        // if a semaphore deinits below the value it was created with.
        let semaphore = DispatchSemaphore(value: 0)
        semaphore.signal()

        await awaitSignal(semaphore)

        // The signal was consumed, so a second drain finds nothing.
        #expect(!consumedSignal(semaphore))
    }

    @Test("a signal that arrives after the wait begins resumes it")
    func resumesOnLateSignal() async {
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = Task { await awaitSignal(semaphore) }

        semaphore.signal()
        await waiter.value

        #expect(!consumedSignal(semaphore))
    }

    @Test("cancelling a task waiting on an unsignalled semaphore ends the wait")
    func cancellationEndsTheWait() async {
        let semaphore = DispatchSemaphore(value: 0)
        let finished = CompletionFlag()
        let waiter = Task {
            await awaitSignal(semaphore)
            finished.markCompleted()
        }
        waiter.cancel()

        // Poll a flag instead of awaiting the task directly: if cancellation is
        // ignored, that await never returns and the whole run hangs with no
        // failure reported. A `.timeLimit` trait cannot help either — Swift
        // Testing enforces it by cancelling, which is the behaviour under test.
        for _ in 0 ..< 500 where !finished.isCompleted {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(finished.isCompleted, "awaitSignal ignored cancellation and never returned")

        // On failure, release the waiter so it does not spin for the rest of
        // the run and so the semaphore deinits at the value it started with.
        if !finished.isCompleted { semaphore.signal() }
        await waiter.value

        #expect(!consumedSignal(semaphore))
    }
}
