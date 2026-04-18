import Foundation

/// A single observation from a scanner or executor: one filesystem path
/// inspected or acted on. Drives the live "Event Horizon Console" in the
/// Smart Uninstaller and is also useful for diagnostics.
///
/// The event transport is opaque — consumers decide how to render each
/// outcome. The producer emits events roughly in file-visit order; the
/// main-actor observer guarantees in-order delivery.
public struct ScanProgressEvent: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Path was inspected and found not to be interesting.
        case checked
        /// Path matched a rule (app bundle, remnant, or target for removal).
        case match
        /// Path was deliberately skipped (exclusion rule, missing dependency, …).
        case skipped(reason: String)
        /// Operation on the path failed. `reason` is safe to show to users.
        case failed(reason: String)
    }

    public let path: String
    public let outcome: Outcome
    /// Bytes attributable to this path, when known. Matches/successful
    /// deletions include this; checked/skipped events typically do not.
    public let bytes: Int64?
    public let timestamp: Date

    public init(
        path: String,
        outcome: Outcome,
        bytes: Int64? = nil,
        timestamp: Date = Date()
    ) {
        self.path = path
        self.outcome = outcome
        self.bytes = bytes
        self.timestamp = timestamp
    }
}

/// Observer for a stream of `ScanProgressEvent`s. Producers emit; one
/// observer at a time. `didEmit` must be safe to call from any isolation
/// context — conformers are expected to bounce to the main actor as needed.
public protocol ScanProgressObserving: AnyObject, Sendable {
    func didEmit(_ event: ScanProgressEvent)
}
