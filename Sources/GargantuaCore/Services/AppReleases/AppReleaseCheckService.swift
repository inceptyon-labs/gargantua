import Foundation

/// Runs one check: asks every source about every app concurrently, then
/// resolves each app's row.
public protocol AppReleaseChecking: Sendable {
    func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow]
}

public struct AppReleaseCheckService: AppReleaseChecking {
    private let catalog: AppReleaseCatalogSource
    private let homebrew: HomebrewCaskSource
    private let sources: [any AppReleaseSourcing]
    private let installedCaskTokens: @Sendable () -> Set<String>
    private let osVersion: OperatingSystemVersion

    /// - Parameters:
    ///   - catalog: Consulted first; apps it covers are not sent to the plain
    ///     Sparkle source, so one feed is never fetched twice.
    ///   - homebrew: Supplies cask releases and, for every app it matches, the
    ///     cask token that decides whether brew manages the app.
    ///   - sources: The other automatic sources (Sparkle, App Store).
    public init(
        catalog: AppReleaseCatalogSource,
        homebrew: HomebrewCaskSource,
        sources: [any AppReleaseSourcing],
        installedCaskTokens: @escaping @Sendable () -> Set<String> = { HomebrewCaskroomProbe().installedTokens() },
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.catalog = catalog
        self.homebrew = homebrew
        self.sources = sources
        self.installedCaskTokens = installedCaskTokens
        self.osVersion = osVersion
    }

    /// Production wiring: one https-only client shared by every source.
    public static func makeDefault(http: any AppReleaseHTTPFetching = DefaultAppReleaseHTTPClient()) -> AppReleaseCheckService {
        let sparkle = SparkleAppcastSource(http: http)
        return AppReleaseCheckService(
            catalog: AppReleaseCatalogSource(http: http, sparkle: sparkle),
            homebrew: HomebrewCaskSource(index: HomebrewCaskIndex(http: http)),
            sources: [sparkle, MASLookupSource(http: http)]
        )
    }

    public func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
        let candidates = apps.filter { !preferences.ignoredBundleIDs.contains($0.bundleID) }
        let covered = catalog.coveredBundleIDs
        let catalog = self.catalog
        let sources = self.sources

        async let brew = homebrew.lookUp(candidates)
        var byKind = await withTaskGroup(of: (AppReleaseSourceKind, [String: AppReleaseSourceOutcome]).self) { group in
            group.addTask { (.catalog, await catalog.lookUp(candidates)) }
            for source in sources {
                let input = source.kind == .sparkle ? candidates.filter { !covered.contains($0.bundleID) } : candidates
                group.addTask { (source.kind, await source.lookUp(input)) }
            }
            var collected: [AppReleaseSourceKind: [String: AppReleaseSourceOutcome]] = [:]
            for await (kind, outcomes) in group {
                collected[kind] = outcomes
            }
            return collected
        }
        let casks = await brew
        byKind[.homebrewCask] = casks.outcomes

        let caskroom = installedCaskTokens()
        return apps.map { app in
            var outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [:]
            for (kind, results) in byKind {
                if let outcome = results[app.bundleID] { outcomes[kind] = outcome }
            }
            return AppReleaseResolver.resolve(
                app: app,
                outcomes: outcomes,
                brewManagedToken: casks.tokens[app.bundleID].flatMap { caskroom.contains($0) ? $0 : nil },
                preferences: preferences,
                osVersion: osVersion
            )
        }
    }
}
