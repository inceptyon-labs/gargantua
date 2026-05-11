import Foundation

extension ClaudeCodeAgentSessionController {
    /// End-of-session fallback. Runs only when:
    /// 1. The terminal status is `.completed` (failures and cancellations
    ///    surface their own state and the user shouldn't be asked to clean
    ///    items the agent never finished reasoning about).
    /// 2. No gate with hydratable `proposedItemIDs` was raised — that means
    ///    the agent did NOT call `mcp__gargantua__clean` with item_ids, so
    ///    nothing routed into the review modal through the normal path.
    /// 3. The host-side scan cache is non-empty — i.e. the agent at least
    ///    ran a scan, even if it never proposed items.
    /// 4. There is no pending approval already (a prior gate hydration may
    ///    have set one).
    ///
    /// When all four hold, synthesize a gate carrying every cached safe/
    /// review item ID, hydrate it into `pendingApproval`, and add it to
    /// `approvalGates` so `confirmPendingApproval` can mark it `.approved`
    /// once cleanup runs. Protected items are excluded — `MCPCleanToolHandler`
    /// hard-rejects them and surfacing them in the modal would only invite
    /// confusion.
    func surfaceScanCacheModalIfAgentDidNotPropose() {
        guard case .completed = status else { return }
        guard pendingApproval == nil else { return }
        let agentAlreadyProposed = approvalGates.contains { !$0.proposedItemIDs.isEmpty }
        guard !agentAlreadyProposed else { return }

        let actionable = scanCache.allEntries().filter(\.safety.isActionable)
        guard !actionable.isEmpty else { return }

        // Sort by size desc so the modal opens with the heaviest cleanup
        // candidates at the top — same ordering Deep Scan defaults to.
        let sorted = actionable.sorted { $0.size > $1.size }
        let proposedItemIDs = sorted.map(\.id)

        let synthesizedGate = ClaudeCodeAgentApprovalGate(
            sessionID: activeSessionID ?? UUID(),
            summary: proposedItemIDs.count == 1
                ? "Agent finished without proposing items — surfacing 1 scanned item."
                : "Agent finished without proposing items — surfacing \(proposedItemIDs.count) scanned items.",
            rawTranscript: "[host fallback: hydrated from scan cache]",
            proposedItemIDs: proposedItemIDs
        )
        approvalGates.append(synthesizedGate)
        pendingApproval = ClaudeCodeAgentPendingApproval(
            gateID: synthesizedGate.id,
            items: sorted,
            unresolvedItemIDs: []
        )
    }

    func appendStreamEvent(_ event: ClaudeCodeStreamEvent) {
        streamEvents.append(event)
        if case .terminal(let result) = event {
            terminalResult = result
        }
        // Mirror agent scan results into the host-side cache so a later
        // approve(_:) can hydrate gate.proposedItemIDs into ScanResults.
        // Within a session we ACCUMULATE rather than replace: Sonnet may
        // run more than one scan, and its final clean call can reference
        // IDs from any of them. Replacing would evict earlier IDs and
        // cause `lookupAll` to misclassify them as unresolved → the user
        // would see the Smart Uninstaller fallback even though the IDs
        // are perfectly valid scan results. The cache is cleared in
        // `start()` so old sessions don't leak.
        if case let .toolResult(_, _, _, .scanResults(items)) = event {
            let scanResults = items.compactMap(Self.scanResult(from:))
            if !scanResults.isEmpty {
                scanCache.merge(adding: scanResults)
            }
        }
        // Capture the agent's prose summary so the review modal can show
        // "Why these items" alongside the rows. Multiple assistant_text
        // events can arrive during a run; we keep the most recent
        // non-empty one because it's typically the agent's final summary
        // accompanying the clean call.
        if case let .assistantText(text) = event {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lastAssistantText = trimmed
            }
        }
    }

    /// Convert a wire-shape `MCPScanItem` (carried in the parser's payload)
    /// back to the `ScanResult` shape `CleanupEngine` and `DeepCleanView`
    /// consume. Lossy on `size` (round-trips through the formatted display
    /// string), `tags` (not on wire), `regenerates` and `regenerateCommand`
    /// (not on wire). Returns nil when the safety raw value is unknown.
    static func scanResult(from item: MCPScanItem) -> ScanResult? {
        guard let safety = SafetyLevel(rawValue: item.safety) else { return nil }
        return ScanResult(
            id: item.id,
            name: item.name,
            path: item.path,
            size: bytesFromFormattedSize(item.size) ?? 0,
            safety: safety,
            confidence: item.confidence,
            explanation: item.explanation,
            source: SourceAttribution(name: item.source),
            lastAccessed: item.lastAccessed,
            category: item.category
        )
    }

    /// Inverse of `AlertItem.formatBytes(_:)` — best-effort parser for the
    /// formatted size strings (e.g. "4.1 KB", "23 GB") the MCP wire shape
    /// carries. Approximate at small magnitudes; the agent's
    /// recommendations are coarse-grained anyway, so the difference between
    /// 4_100 and 4_096 bytes doesn't matter for cleanup display.
    private static func bytesFromFormattedSize(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let value = Double(parts[0]) else {
            return Int64(trimmed)
        }
        let unit = parts[1].lowercased()
        let multiplier: Double
        switch unit {
        case "bytes", "byte", "b": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

/// Lightweight `ScanProgressObserving` adapter used by the agent's cleanup
/// confirm path. CleanupEngine emits a `match` or `failed` event per item;
/// we don't care which — both mean the engine finished one row, so the
/// progress counter can advance. The closure is invoked from whatever
/// isolation context CleanupEngine emits from; the caller is responsible
/// for bouncing to the main actor.
final class AgentCleanupProgressObserver: ScanProgressObserving {
    private let onAdvance: @Sendable () -> Void

    init(onAdvance: @escaping @Sendable () -> Void) {
        self.onAdvance = onAdvance
    }

    func didEmit(_ event: ScanProgressEvent) {
        onAdvance()
    }
}
