import Foundation

// Scan-session cache for resolving MCP `clean` inputs back to the concrete
// `ScanResult` values they refer to. The MCP `clean` tool receives item IDs
// (strings) that the caller pulled from a prior `scan` response; the handler
// needs the full `ScanResult` to route the cleanup to `CleanupEngine` and to
// consult each item's `safety` for the protected-hard-reject guardrail.
//
// Semantics: last-scan-wins. Every successful scan replaces the cache in one
// atomic step, so `clean` always resolves against the most recent scan. A
// prior scan's IDs become invalid the moment a newer scan lands, which makes
// stale-ID bugs surface loudly as `invalidParams` at the handler boundary
// rather than silently cleaning the wrong item.
//
// A simple NSLock-guarded dictionary is enough: the MCP stdio transport
// processes one request at a time, so contention is nil in production. The
// lock exists to keep the scan- and clean-handler code ergonomic (plain
// `func` methods, no actor hops) and to defend against a future transport
// that parallelises request handling.

/// Last-scan-wins cache mapping `ScanResult.id` to the full item.
///
/// Written by `MCPScanToolHandler` after a successful scan; read by
/// `MCPCleanToolHandler` to resolve the `item_ids` payload into the original
/// `ScanResult` values.
public final class MCPScanSessionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ScanResult] = [:]

    public init() {}

    /// Replace the cache contents with the given scan results. Items whose
    /// IDs collide within `results` resolve to the last occurrence — the
    /// scanner's ID contract forbids duplicates, so this is defensive only.
    public func replace(with results: [ScanResult]) {
        var next: [String: ScanResult] = [:]
        next.reserveCapacity(results.count)
        for item in results {
            next[item.id] = item
        }
        lock.lock()
        entries = next
        lock.unlock()
    }

    /// Insert/update entries from `results` without dropping anything that
    /// is already in the cache. Used by the agent session controller's
    /// host-side mirror: when Sonnet runs multiple scans in a single
    /// session (e.g. one broad sweep then a focused follow-up), the agent's
    /// final `clean` call may reference IDs from any of those scans.
    /// Last-scan-wins semantics — what the in-process MCP server uses —
    /// would evict the earlier IDs and cause `lookupAll` to return
    /// everything as unknown, surfacing the wrong "use Smart Uninstaller"
    /// fallback. Accumulating across scans preserves every ID the agent
    /// could legitimately propose.
    public func merge(adding results: [ScanResult]) {
        lock.lock()
        for item in results {
            entries[item.id] = item
        }
        lock.unlock()
    }

    /// Lookup a single item by ID. Returns nil for unknown IDs.
    public func lookup(id: String) -> ScanResult? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    /// Partition the requested IDs into those that resolve against the cache
    /// and those that do not. Preserves the caller's order in both outputs,
    /// so the handler can report unknown IDs verbatim for easier debugging.
    ///
    /// Duplicated IDs in `ids` are preserved in `found` (the same resolved
    /// item appears twice). The handler treats that as a client-side mistake
    /// upstream and should reject it before reaching here; this method does
    /// not dedupe.
    public func lookupAll(ids: [String]) -> (found: [ScanResult], unknown: [String]) {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var found: [ScanResult] = []
        var unknown: [String] = []
        found.reserveCapacity(ids.count)
        for id in ids {
            if let item = snapshot[id] {
                found.append(item)
            } else {
                unknown.append(id)
            }
        }
        return (found, unknown)
    }

    /// Current number of entries. Exposed for tests and diagnostics.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Whether the cache is empty.
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// Drop all entries. Not currently used in production but handy for tests
    /// that want to isolate scenarios without reallocating a fresh cache.
    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Snapshot of every entry in the cache, in unspecified order. Used by
    /// the agent session controller's end-of-run fallback: if the agent
    /// finished without proposing items via `mcp__gargantua__clean`, the
    /// controller hydrates the cache contents directly into the review
    /// modal so the user gets the same actionable handoff Deep Scan
    /// produces, regardless of what the agent did or didn't do.
    public func allEntries() -> [ScanResult] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.values)
    }
}
