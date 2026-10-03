import Foundation

/// Reconciles scan results whose paths overlap.
///
/// Two rules can propose the same path, or a folder plus something inside it:
/// the broad `user_caches` rule lists every `~/Library/Caches/<app>` folder
/// while a browser rule lists a cache inside one, locked while the browser
/// runs. Cleaning the folder removes everything in it, so the folder takes the
/// strictest safety level and any running-app lock among the results it
/// contains. Command actions, Ollama models and Hugging Face revision prunes
/// aren't plain removals of their `path`, so they don't take part.
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

    /// Merge exact duplicates (first occurrence keeps its position), then raise
    /// every folder to the strictest safety and lock among the results inside it.
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

    private static func raising(_ container: ScanResult, toward contained: ScanResult) -> ScanResult {
        var raised = container
        if rank(contained.safety) > rank(raised.safety) {
            raised.safety = contained.safety
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
