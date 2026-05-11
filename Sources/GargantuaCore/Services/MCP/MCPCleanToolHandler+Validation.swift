import Foundation

extension MCPCleanToolHandler {

    /// Returns the first id that appears more than once in `ids`, or nil if
    /// every id is unique. Preserves the caller's order so the error message
    /// points at the first offending entry.
    static func firstDuplicate(in ids: [String]) -> String? {
        var seen: Set<String> = []
        seen.reserveCapacity(ids.count)
        for id in ids {
            if seen.contains(id) { return id }
            seen.insert(id)
        }
        return nil
    }

    static func resolveMethod(_ raw: String) -> CleanupMethod? {
        switch raw {
        case "trash": return .trash
        case "delete": return .delete
        default: return nil
        }
    }

    static func unknownIDsMessage(_ unknown: [String]) -> String {
        let preview = unknown.prefix(5).joined(separator: ", ")
        let more = unknown.count > 5 ? " and \(unknown.count - 5) more" : ""
        return "Unknown item_ids: \(preview)\(more). "
            + "IDs must come from the most recent scan result."
    }

    static func protectedRejectMessage(_ protected: [ScanResult]) -> String {
        let preview = protected.prefix(3).map(\.id).joined(separator: ", ")
        let more = protected.count > 3 ? " and \(protected.count - 3) more" : ""
        return "Request rejected: \(protected.count) protected item(s) cannot be cleaned via MCP "
            + "(\(preview)\(more))."
    }

    static func rateLimitMessage(
        window: TimeInterval,
        maxOps: Int,
        retryAfter: TimeInterval
    ) -> String {
        let windowSeconds = Int(window.rounded())
        let retrySeconds = max(1, Int(retryAfter.rounded(.up)))
        let budget = maxOps == 1
            ? "1 clean op per \(windowSeconds)s"
            : "\(maxOps) clean ops per \(windowSeconds)s"
        return "MCP clean rate limit exceeded (\(budget) per client). "
            + "Cool-down active; retry in \(retrySeconds)s."
    }
}
