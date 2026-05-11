import Foundation

extension MCPCleanToolHandler {

    /// Shape a successful `CleanupResult` into an `MCPCleanOutput`. Per-item
    /// outcomes fold the engine's two-state success/fail into the three-state
    /// wire vocabulary `moved | skipped | failed`. Task 2 does not produce
    /// `"skipped"` itself — protected items are rejected upstream before the
    /// engine runs, so every engine result maps to `moved` or `failed`. The
    /// `skipped` slot stays in the vocabulary so later tasks (e.g. rate-limit
    /// partial skips) can emit it without a wire format change.
    ///
    /// `bytes_freed` and `freed` are sourced from `ScanResult.size` (the
    /// scan-time sample) rather than actual post-clean disk delta — engine
    /// doesn't currently track actual bytes removed (e.g. the
    /// `emptyTrashContainer` path touches whatever Trash contains now, not
    /// what it contained at scan time). Agents should treat `freed` as a
    /// best-effort estimate, not a ground truth.
    static func makeResult(
        result: CleanupResult,
        method: CleanupMethod,
        auditID: String
    ) throws -> MCPToolCallResult {
        var perItem: [MCPCleanItemResult] = []
        perItem.reserveCapacity(result.itemResults.count)
        var movedCount = 0
        var totalFreed: Int64 = 0

        for entry in result.itemResults {
            if entry.succeeded {
                movedCount += 1
                totalFreed += entry.item.size
                perItem.append(MCPCleanItemResult(
                    id: entry.item.id,
                    outcome: "moved",
                    reason: nil,
                    bytesFreed: entry.item.size
                ))
            } else {
                perItem.append(MCPCleanItemResult(
                    id: entry.item.id,
                    outcome: "failed",
                    reason: entry.error,
                    bytesFreed: nil
                ))
            }
        }

        let output = MCPCleanOutput(
            cleaned: movedCount,
            freed: AlertItem.formatBytes(totalFreed),
            method: method.rawValue,
            auditID: auditID,
            perItem: perItem
        )
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: summary(for: output))
    }

    /// Dry-run plan: present the set as if every item would be successfully
    /// moved. Bytes are summed verbatim from the scan cache — the preview
    /// matches the scan's reported size rather than re-sampling disk. The
    /// caller opted into dry-run by setting `dry_run: true`; we do not also
    /// add a top-level flag to the output because the request itself already
    /// documents the mode.
    static func makeDryRunResult(
        items: [ScanResult],
        method: CleanupMethod,
        auditID: String
    ) throws -> MCPToolCallResult {
        var perItem: [MCPCleanItemResult] = []
        perItem.reserveCapacity(items.count)
        var totalFreed: Int64 = 0

        for item in items {
            totalFreed += item.size
            perItem.append(MCPCleanItemResult(
                id: item.id,
                outcome: "moved",
                reason: nil,
                bytesFreed: item.size
            ))
        }

        let output = MCPCleanOutput(
            cleaned: items.count,
            freed: AlertItem.formatBytes(totalFreed),
            method: method.rawValue,
            auditID: auditID,
            perItem: perItem
        )
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(
            payload,
            summary: "[dry-run] would clean \(items.count) item(s); \(output.freed) reclaimable."
        )
    }

    static func summary(for output: MCPCleanOutput) -> String {
        let total = output.perItem.count
        let failed = total - output.cleaned
        if failed > 0 {
            return "Cleaned \(output.cleaned) of \(total) item(s); \(failed) failed. "
                + "Freed \(output.freed)."
        }
        return "Cleaned \(output.cleaned) item(s); freed \(output.freed)."
    }
}
