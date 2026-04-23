import Foundation

// Sliding-window rate limiter for MCP destructive tools (PRD §7.4).
//
// Phase 3 caps clean operations at 1 per 60 seconds per MCP client to stop an
// agent runaway from draining the disk faster than a human can notice. The
// limiter is scoped per-(client, tool) rather than per-process so that a
// future `purge` or `uninstall` tool can share this limiter with its own
// budget, and client A cannot starve client B's budget when they share a
// server process (future SSE transport, `gargantua-vdeg`).
//
// Implementation notes:
//
// - Sliding window, not fixed bucket: we store the timestamps of prior
//   events and evict ones older than `window` on every check. A fixed bucket
//   would let a client submit two ops at second 59 and second 61 and pass the
//   limit under the plain-English reading, which defeats the purpose.
// - Synchronous API. The `MCPToolHandler` contract is sync; an actor would
//   force every handler caller to become async. Contention is nil in
//   production (stdio serialises requests); the lock defends against a
//   future parallel transport.
// - Injectable clock. Tests must not rely on wall-clock sleeps to cross the
//   window boundary.

/// Outcome of a rate limit check.
public enum MCPRateLimitResult: Equatable, Sendable {
    /// Under the budget. The caller recorded this event and should proceed.
    case allowed
    /// Over the budget. Caller should reject the request with an
    /// `invalidParams`-shaped error referencing `retryAfter`.
    case rejected(retryAfter: TimeInterval)
}

/// Per-(clientID, tool) sliding-window rate limiter.
///
/// Default budget is 1 operation per 60 seconds, matching PRD §7.4. Other
/// destructive tools can share the same limiter instance by passing a
/// different `tool` string.
public final class MCPRateLimiter: @unchecked Sendable {

    /// Clock source. Overridden by tests; defaults to wall-clock `Date()`.
    public typealias Clock = @Sendable () -> Date

    public let window: TimeInterval
    public let maxOps: Int
    private let clock: Clock
    private let lock = NSLock()
    private var events: [Key: [Date]] = [:]

    /// - Parameters:
    ///   - window: Length of the sliding window in seconds. Events older than
    ///     this are evicted from the budget on every check. Defaults to 60.
    ///   - maxOps: Maximum events allowed within the window. Defaults to 1.
    ///   - clock: Time source. Defaults to `Date()`; tests inject a virtual
    ///     clock.
    public init(
        window: TimeInterval = 60,
        maxOps: Int = 1,
        clock: @escaping Clock = { Date() }
    ) {
        precondition(window > 0, "MCPRateLimiter window must be positive")
        precondition(maxOps >= 1, "MCPRateLimiter maxOps must be at least 1")
        self.window = window
        self.maxOps = maxOps
        self.clock = clock
    }

    /// Check whether another operation is permitted for `(clientID, tool)`,
    /// and if so record it. Combined check-and-record keeps callers from
    /// racing past the budget between a separate "check" and "record" call.
    ///
    /// When rejected, `retryAfter` is the number of seconds until the oldest
    /// event in the window ages out (so `now + retryAfter` is the earliest
    /// moment the next op will succeed, assuming no further events land).
    public func recordAndCheck(clientID: String, tool: String) -> MCPRateLimitResult {
        let now = clock()
        let cutoff = now.addingTimeInterval(-window)
        let key = Key(clientID: clientID, tool: tool)

        lock.lock()
        defer { lock.unlock() }

        // Evict expired events.
        var history = events[key] ?? []
        history.removeAll { $0 < cutoff }

        if history.count >= maxOps {
            // Oldest event still in the window determines when the next op
            // will be admitted. Adding `window` to its timestamp yields the
            // absolute time it ages out.
            let oldest = history.first ?? now
            let retry = max(0, oldest.addingTimeInterval(window).timeIntervalSince(now))
            // Write back the pruned history so the next check doesn't
            // re-evict what we just pruned.
            events[key] = history
            return .rejected(retryAfter: retry)
        }

        history.append(now)
        events[key] = history
        return .allowed
    }

    /// Inspect the current budget for `(clientID, tool)` without recording a
    /// new event. Returns the number of events still inside the window.
    /// Exposed for diagnostics and tests.
    public func eventCount(clientID: String, tool: String) -> Int {
        let cutoff = clock().addingTimeInterval(-window)
        let key = Key(clientID: clientID, tool: tool)
        lock.lock()
        defer { lock.unlock() }
        let pruned = (events[key] ?? []).filter { $0 >= cutoff }
        events[key] = pruned
        return pruned.count
    }

    /// Drop all recorded events. Exposed for tests.
    public func reset() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    private struct Key: Hashable {
        let clientID: String
        let tool: String
    }
}
