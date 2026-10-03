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

    /// Sequence number of `events[0]`. Increments when events are dropped
    /// off the front of the ring buffer so callers that need a stable row
    /// identity can compute `firstSequence + index` and keep referring to
    /// the same event after buffer rollover.
    public private(set) var firstSequence: Int = 0

    /// Running count of `.match` outcomes since the last `clear()`.
    public private(set) var matchCount: Int = 0

    /// Running count of `.failed` outcomes since the last `clear()`.
    public private(set) var failureCount: Int = 0

    /// Running sum of `bytes` on match events, in bytes. A match inside an
    /// already-matched folder adds nothing, and a folder matched after
    /// something inside it replaces that item's bytes.
    public private(set) var totalBytes: Int64 = 0

    /// Bytes counted per matched path, for `totalBytes`' nesting rule.
    private var countedBytesByPath: [String: Int64] = [:]

    public let bufferCap: Int

    /// Sequence number the next appended event will get. Unlike `events.count`
    /// it keeps climbing after the buffer fills, so views can react to every
    /// new event.
    public var nextSequence: Int {
        firstSequence + events.count
    }

    /// One buffered event with its stable sequence number, for row identity
    /// that survives buffer rollover.
    public struct SequencedEvent: Identifiable {
        public let id: Int
        public let event: ScanProgressEvent
    }

    public var sequencedEvents: [SequencedEvent] {
        events.enumerated().map { SequencedEvent(id: firstSequence + $0.offset, event: $0.element) }
    }

    /// Nonisolated staging buffer so a scanner emitting thousands of events from
    /// a background task batches them into one main-actor hop per runloop tick
    /// instead of scheduling one `Task` per event.
    private let pending = PendingEvents()

    public nonisolated init(bufferCap: Int = 200) {
        self.bufferCap = bufferCap
    }

    public nonisolated func didEmit(_ event: ScanProgressEvent) {
        // Only the pass that transitions the buffer from idle schedules a flush;
        // events emitted before it runs ride along in the same drain, preserving
        // order and completeness.
        guard pending.stage(event) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.append(contentsOf: self.pending.drain())
        }
    }

    /// Thread-safe FIFO staging area that also tracks whether a flush is already
    /// scheduled, so bursts collapse to a single main-actor drain.
    private final class PendingEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [ScanProgressEvent] = []
        private var flushScheduled = false

        /// Appends `event`; returns `true` when the caller should schedule a
        /// flush (the buffer was idle), `false` when one is already pending.
        func stage(_ event: ScanProgressEvent) -> Bool {
            lock.lock(); defer { lock.unlock() }
            buffer.append(event)
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }

        /// Returns the staged events in order and re-arms the scheduler.
        func drain() -> [ScanProgressEvent] {
            lock.lock(); defer { lock.unlock() }
            let drained = buffer
            buffer.removeAll(keepingCapacity: true)
            flushScheduled = false
            return drained
        }
    }

    /// Main-actor append used directly from tests and internal callers.
    public func append(_ event: ScanProgressEvent) {
        append(contentsOf: [event])
    }

    /// Appends a drained batch with one write per property, so observers see a
    /// single change per batch instead of one per event.
    public func append(contentsOf batch: [ScanProgressEvent]) {
        guard !batch.isEmpty else { return }
        var updated = events
        updated.append(contentsOf: batch)
        let dropped = updated.count - bufferCap
        if dropped > 0 {
            updated.removeFirst(dropped)
        }

        var matches = 0
        var failures = 0
        var bytes: Int64 = 0
        for event in batch {
            switch event.outcome {
            case .match:
                matches += 1
                bytes += distinctMatchBytes(path: event.path, bytes: event.bytes ?? 0)
            case .failed:
                failures += 1
            case .checked, .skipped:
                break
            }
        }

        events = updated
        if dropped > 0 { firstSequence += dropped }
        if matches > 0 {
            matchCount += matches
            totalBytes += bytes
        }
        if failures > 0 { failureCount += failures }
    }

    /// Reset the buffer and all aggregate counters. The sequence counter is
    /// preserved across clears so IDs never collide with previously-swallowed
    /// events that a view might still remember.
    public func clear() {
        firstSequence += events.count
        events = []
        matchCount = 0
        failureCount = 0
        totalBytes = 0
        countedBytesByPath = [:]
    }

    private func distinctMatchBytes(path: String, bytes: Int64) -> Int64 {
        guard countedBytesByPath[path] == nil else { return 0 }
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.count > 1 {
            if countedBytesByPath[ancestor] != nil { return 0 }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let nested = countedBytesByPath.filter { $0.key.hasPrefix(prefix) }
        for key in nested.keys {
            countedBytesByPath[key] = nil
        }
        countedBytesByPath[path] = bytes
        return bytes - nested.values.reduce(0, +)
    }
}
