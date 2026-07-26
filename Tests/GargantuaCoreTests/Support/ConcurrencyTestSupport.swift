import Foundation

/// `DispatchSemaphore.wait()` is `noasync`. This blocks a global-queue thread
/// rather than the caller's async context, so the wait is awaitable without
/// tripping the Swift 6 diagnostic.
func awaitSignal(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}
