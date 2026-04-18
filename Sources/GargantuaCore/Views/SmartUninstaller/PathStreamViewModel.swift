import Foundation
import Observation

/// View model backing the Event Horizon Console.
///
/// Receives `ScanProgressEvent`s from scanners/executors on any thread,
/// bounces to the main actor, and exposes a bounded ring buffer plus
/// aggregate stats (match count, failure count, bytes) for the view to
/// render. Call `clear()` between phases when a fresh log is desired.
@MainActor
@Observable
public final class PathStreamViewModel: ScanProgressObserving {
    /// Event log, capped at `bufferCap`. Oldest events drop first.
    public private(set) var events: [ScanProgressEvent] = []

    /// Running count of `.match` outcomes since the last `clear()`.
    public private(set) var matchCount: Int = 0

    /// Running count of `.failed` outcomes since the last `clear()`.
    public private(set) var failureCount: Int = 0

    /// Running sum of `bytes` on match events, in bytes.
    public private(set) var totalBytes: Int64 = 0

    public let bufferCap: Int

    public nonisolated init(bufferCap: Int = 200) {
        self.bufferCap = bufferCap
    }

    public nonisolated func didEmit(_ event: ScanProgressEvent) {
        Task { @MainActor [weak self] in
            self?.append(event)
        }
    }

    /// Main-actor append used directly from tests and internal callers.
    public func append(_ event: ScanProgressEvent) {
        events.append(event)
        if events.count > bufferCap {
            events.removeFirst(events.count - bufferCap)
        }
        switch event.outcome {
        case .match:
            matchCount += 1
            totalBytes += event.bytes ?? 0
        case .failed:
            failureCount += 1
        case .checked, .skipped:
            break
        }
    }

    /// Reset the buffer and all aggregate counters.
    public func clear() {
        events = []
        matchCount = 0
        failureCount = 0
        totalBytes = 0
    }
}
