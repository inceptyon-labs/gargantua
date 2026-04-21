import Foundation

/// Deterministic fallback for natural-language scan filters.
///
/// This keeps the search affordance useful when no local model is available,
/// and gives model-backed engines a conservative baseline for common product
/// domains. It only emits the allow-listed DSL.
enum ScanFilterTemplate {
    static func filter(for query: String) -> ScanFilterSet? {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        var bundleIDs: [String] = []
        var pathGlobs: [String] = []
        var categories: [String] = []
        var safetyLevels: [SafetyLevel] = []
        let terms = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        if normalized.contains("xcode") || normalized.contains("derived data") {
            bundleIDs.append("com.apple.dt.Xcode")
            pathGlobs.append("*/Library/Developer/Xcode/*")
            categories.append("dev_artifacts")
        }

        if terms.contains("docker") {
            pathGlobs.append("*/.docker/*")
            categories.append("docker")
        }

        if terms.contains("homebrew") || terms.contains("brew") {
            pathGlobs.append("*/Homebrew/*")
            categories.append("homebrew")
        }

        if terms.contains("chrome") {
            bundleIDs.append("com.google.Chrome")
            pathGlobs.append("*/Google/Chrome/*")
            categories.append("browser_cache")
        }

        if terms.contains("safari") {
            bundleIDs.append("com.apple.Safari")
            pathGlobs.append("*/Safari/*")
            categories.append("browser_cache")
        }

        if terms.contains("safe") {
            safetyLevels.append(.safe)
        }
        if terms.contains("review") {
            safetyLevels.append(.review)
        }
        if terms.contains("protected") {
            safetyLevels.append(.protected_)
        }

        let filter = ScanFilterSet(
            bundleIDs: bundleIDs,
            pathGlobs: pathGlobs,
            categories: categories,
            safetyLevels: safetyLevels
        )
        return filter.isEmpty ? nil : filter
    }
}
