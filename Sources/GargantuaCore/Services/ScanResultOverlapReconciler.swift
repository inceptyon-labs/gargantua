import Foundation

/// Reconciles scan results whose paths overlap.
///
/// Two rules can propose the same path, or a folder plus something inside it:
/// the broad `user_caches` rule lists every `~/Library/Caches/<app>` folder
/// while a browser rule lists a cache inside one, locked while the browser
/// runs. Cleaning the folder removes everything in it, so a folder takes any
/// running-app lock, and any protected status, among the results it contains.
/// A contained `review` result does not demote the folder: generic review
/// rules (e.g. Application Support `Cache_Data`) also match inside folders a
/// specific rule knows are safe, like Claude's or Discord's own cache.
/// Command actions, Ollama models and Hugging Face revision prunes aren't plain
/// removals of their `path`, so they don't take part.
enum ScanResultOverlapReconciler {
    /// Of two results for the same path, keep the one with the stricter safety
    /// (its explanation matches), carrying over the other's app lock if the
    /// kept one has none. Ties keep `existing`.
    static func stricter(_ existing: ScanResult, _ incoming: ScanResult) -> ScanResult {
        var kept = rank(incoming.safety) > rank(existing.safety) ? incoming : existing
        let other = kept.id == existing.id ? incoming : existing
        if kept.blockedByApp == nil {
            kept.blockedByApp = other.blockedByApp
        }
        return kept
    }

    /// Merge exact duplicates (first occurrence keeps its position), then give
    /// every folder the locks and protected status of the results inside it.
    static func reconcile(_ results: [ScanResult]) -> [ScanResult] {
        var merged: [ScanResult] = []
        var indexByPath: [String: Int] = [:]
        merged.reserveCapacity(results.count)
        for result in results {
            guard participates(result) else {
                merged.append(result)
                continue
            }
            let key = normalized(result.path)
            if let existing = indexByPath[key] {
                merged[existing] = stricter(merged[existing], result)
            } else {
                indexByPath[key] = merged.count
                merged.append(result)
            }
        }

        var reconciled = merged
        for result in merged where participates(result) {
            var ancestor = (normalized(result.path) as NSString).deletingLastPathComponent
            while ancestor.count > 1 {
                if let index = indexByPath[ancestor] {
                    reconciled[index] = raising(reconciled[index], toward: result)
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        return reconciled
    }

    /// For each result inside another result's folder, the IDs of the results
    /// containing it. A later result for an already-seen path counts as
    /// contained by the first.
    static func containers(in results: [ScanResult]) -> [String: [String]] {
        var idByPath: [String: String] = [:]
        var containers: [String: [String]] = [:]
        for result in results where participates(result) {
            let key = normalized(result.path)
            if let first = idByPath[key], first != result.id {
                containers[result.id, default: []].append(first)
            } else if idByPath[key] == nil {
                idByPath[key] = result.id
            }
        }
        for result in results where participates(result) {
            var ancestor = (normalized(result.path) as NSString).deletingLastPathComponent
            while ancestor.count > 1 {
                if let containerID = idByPath[ancestor] {
                    containers[result.id, default: []].append(containerID)
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        return containers
    }

    /// Total size of `results`, counting a result inside another one in the
    /// same set only once: the folder's size already includes it.
    static func distinctBytes(_ results: [ScanResult], containers: [String: [String]]? = nil) -> Int64 {
        let containers = containers ?? self.containers(in: results)
        let ids = Set(results.map(\.id))
        return results.reduce(Int64(0)) { total, result in
            if let outer = containers[result.id], outer.contains(where: ids.contains) {
                return total
            }
            let (sum, overflow) = total.addingReportingOverflow(result.size)
            return overflow ? .max : sum
        }
    }

    private static func raising(_ container: ScanResult, toward contained: ScanResult) -> ScanResult {
        var raised = container
        if contained.safety == .protected_ {
            raised.safety = .protected_
        }
        if raised.blockedByApp == nil {
            raised.blockedByApp = contained.blockedByApp
        }
        return raised
    }

    private static func participates(_ result: ScanResult) -> Bool {
        !(result.isCommandAction || result.isOllamaModel || result.isHuggingFaceRevisionPrune)
    }

    private static func rank(_ safety: SafetyLevel) -> Int {
        switch safety {
        case .safe: 0
        case .review: 1
        case .protected_: 2
        }
    }

    private static func normalized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}
