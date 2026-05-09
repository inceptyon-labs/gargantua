import Foundation

/// Builds the default multi-adapter scan pipeline for a cleanup profile.
public enum ProfileScanAdapterFactory {
    public static func make(
        profile: CleanupProfile,
        scanRoots: [URL]? = nil,
        staleVersionPinnedPaths: Set<String> = [],
        aiModelExcludedPaths: Set<String> = []
    ) throws -> any ScanAdapter {
        let categories = Set(profile.categories)
        let staleVersionPolicy = StaleVersionRetentionPolicy(pinnedPaths: staleVersionPinnedPaths)
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
                    excludedPaths: aiModelExcludedPaths
                ),
            ]
        )
    }
}
