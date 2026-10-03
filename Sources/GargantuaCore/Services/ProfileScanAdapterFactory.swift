import Foundation

/// Builds the default multi-adapter scan pipeline for a cleanup profile.
public enum ProfileScanAdapterFactory {
    /// - Parameter pathExclusions: the user's Settings › Exclusions patterns.
    ///   Every adapter's results are filtered against them; the stale-version
    ///   and AI-model adapters also use them to pin or skip paths while scanning.
    public static func make(
        profile: CleanupProfile,
        scanRoots: [URL]? = nil,
        pathExclusions: Set<String> = []
    ) throws -> any ScanAdapter {
        let categories = Set(profile.categories)
        let staleVersionPolicy = StaleVersionRetentionPolicy(pinnedPaths: pathExclusions)
        return CompositeScanAdapter(
            primary: try NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots),
            bestEffort: [
                CommandActionScanAdapter.loadDefaults(categories: categories),
                StaleVersionScanAdapter.loadDefaults(
                    categories: categories,
                    policy: staleVersionPolicy
                ),
                AIModelIntelligenceScanAdapter.loadDefaults(
                    categories: categories,
                    scanRoots: scanRoots,
                    excludedPaths: pathExclusions
                ),
                OllamaModelScanAdapter.loadDefaults(categories: categories),
                HuggingFaceModelScanAdapter.loadDefaults(categories: categories),
                GitWorktreeScanAdapter.loadDefaults(
                    categories: categories,
                    scanRoots: scanRoots
                ),
                AISessionScanAdapter.loadDefaults(categories: categories),
            ],
            exclusions: PathExclusionMatcher(patterns: pathExclusions)
        )
    }
}
