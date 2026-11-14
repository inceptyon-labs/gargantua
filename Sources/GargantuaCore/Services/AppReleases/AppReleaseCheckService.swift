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
    private let installedCasks: @Sendable () -> [HomebrewInstalledCask]
    private let osVersion: OperatingSystemVersion

    /// - Parameters:
    ///   - catalog: Consulted first; apps it covers are not sent to the plain
    ///     Sparkle source, so one feed is never fetched twice.
    ///   - homebrew: Supplies cask releases and, for every app it matches, a
    ///     cask token that marks the app brew-managed when that cask is installed.
    ///   - sources: The other automatic sources (Sparkle, App Store).
    ///   - installedCasks: The local Caskroom, which decides brew ownership
    ///     for casks the public index doesn't know or can't be reached for.
    public init(
        catalog: AppReleaseCatalogSource,
        homebrew: HomebrewCaskSource,
        sources: [any AppReleaseSourcing],
        installedCasks: @escaping @Sendable () -> [HomebrewInstalledCask] = { HomebrewCaskroomProbe().installedCasks() },
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.catalog = catalog
        self.homebrew = homebrew
        self.sources = sources
        self.installedCasks = installedCasks
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

        let ownership = HomebrewCaskOwnership(casks: installedCasks())
        return apps.map { app in
            var outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [:]
            for (kind, results) in byKind {
                if let outcome = results[app.bundleID] { outcomes[kind] = outcome }
            }
            let indexToken = casks.tokens[app.bundleID]
            let owner = ownership.owner(of: app, indexToken: indexToken)
            if let owner, !ownership.publicIndexDescribes(owner: owner, indexToken: indexToken) {
                outcomes[.homebrewCask] = nil
            }
            return AppReleaseResolver.resolve(
                app: app,
                outcomes: outcomes,
                brewManagedToken: owner,
                preferences: preferences,
                osVersion: osVersion
            )
        }
    }
}
