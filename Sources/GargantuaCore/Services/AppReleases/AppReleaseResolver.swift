import Foundation

/// Turns what each source reported for one app into a row: which release to
/// offer and how it can be installed. Pure; no I/O.
public enum AppReleaseResolver {
    /// - Parameters:
    ///   - outcomes: What each source reported for this app. Sources that
    ///     don't know the app are absent.
    ///   - brewManagedToken: The matched cask token when that cask is also
    ///     installed in the Caskroom, so brew owns the app's updates.
    public static func resolve(
        app: InstalledApp,
        outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome],
        brewManagedToken: String?,
        preferences: AppReleasePreferences,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> AppReleaseRow {
        let sources = AppReleaseSourceKind.allCases.filter { outcomes[$0] != nil }
        func row(_ status: AppReleaseStatus) -> AppReleaseRow {
            AppReleaseRow(app: app, status: status, sources: sources)
        }

        if preferences.ignoredBundleIDs.contains(app.bundleID) { return row(.ignored) }

        // App Store apps update through the App Store only.
        let considered = app.isMAS ? outcomes.filter { $0.key == .appStore } : outcomes.filter { $0.key != .appStore }

        let found = considered.values.compactMap { outcome -> AppReleaseCandidate? in
            if case .found(let candidate) = outcome { return candidate }
            return nil
        }
        let eligible = found.filter { !$0.isPrerelease && runs(on: osVersion, minimum: $0.minimumSystemVersion) }
        let newer = eligible.filter { $0.version.isNewer(than: app.version) }

        guard let chosen = preferred(among: newer) else {
            if let latest = preferred(among: eligible) { return row(.upToDate(latest: latest)) }
            let failures = considered.values.compactMap { outcome -> String? in
                if case .failed(let message) = outcome { return message }
                return nil
            }
            if considered.isEmpty { return row(.untracked) }
            if failures.count == considered.count, let first = failures.first { return row(.failed(first)) }
            return row(.upToDate(latest: nil))
        }

        if preferences.skippedVersions[app.bundleID] == chosen.displayVersion {
            return row(.skippedVersion(chosen.displayVersion))
        }

        if app.isMAS {
            let strategy: AppReleaseInstallStrategy = chosen.vendorURL.map { .openAppStore($0) }
                ?? .linkOnly(nil, reason: .noInstallablePayload)
            return row(.available(chosen, strategy))
        }

        if let token = brewManagedToken {
            return row(brewStatus(chosen: chosen, token: token, outcomes: considered))
        }
        return row(.available(chosen, inPlaceStrategy(for: chosen, app: app)))
    }

    /// Highest version wins. On a tie, a release we can install beats one we
    /// can only link to, then catalog beats Sparkle beats Homebrew.
    static func preferred(among candidates: [AppReleaseCandidate]) -> AppReleaseCandidate? {
        candidates.max { lhs, rhs in
            switch lhs.version.compare(to: rhs.version) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                if isDownloadable(lhs) != isDownloadable(rhs) { return !isDownloadable(lhs) }
                return lhs.source.tieBreakRank > rhs.source.tieBreakRank
            }
        }
    }

    /// Brew owns this app: update through `brew upgrade` when the cask has
    /// the newest release, otherwise only link to it so brew's records stay
    /// true.
    private static func brewStatus(
        chosen: AppReleaseCandidate,
        token: String,
        outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome]
    ) -> AppReleaseStatus {
        if case .found(let cask) = outcomes[.homebrewCask], cask.version.compare(to: chosen.version) == .orderedSame {
            if cask.payloadKind == .pkg {
                return .available(cask, .linkOnly(cask.vendorURL, reason: .packageInstaller))
            }
            return .available(cask, .brewUpgrade(token: token))
        }
        return .available(chosen, .linkOnly(linkURL(for: chosen), reason: .brewCaskBehind))
    }

    private static func inPlaceStrategy(for candidate: AppReleaseCandidate, app: InstalledApp) -> AppReleaseInstallStrategy {
        let link = linkURL(for: candidate)
        if !candidate.allowsInPlaceInstall { return .linkOnly(link, reason: .catalogLinkOnly) }
        if app.isRootOwned { return .linkOnly(link, reason: .rootOwned) }
        if app.teamID == nil { return .linkOnly(link, reason: .unsigned) }
        if candidate.payloadKind == .pkg { return .linkOnly(link, reason: .packageInstaller) }
        if !isDownloadable(candidate) { return .linkOnly(link, reason: .noInstallablePayload) }
        return .inPlace
    }

    private static func isDownloadable(_ candidate: AppReleaseCandidate) -> Bool {
        candidate.downloadURL != nil && candidate.payloadKind.isInstallable && candidate.allowsInPlaceInstall
    }

    private static func linkURL(for candidate: AppReleaseCandidate) -> URL? {
        candidate.vendorURL ?? candidate.releaseNotesURL
    }

    static func runs(on osVersion: OperatingSystemVersion, minimum: String?) -> Bool {
        guard let minimum else { return true }
        let host = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        return AppReleaseVersion.compareComponent(minimum, host) != .orderedDescending
    }
}

/// Runs one check: asks every source about every app concurrently, then
/// resolves each app's row.
public protocol AppReleaseChecking: Sendable {
    func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow]
}

public struct AppReleaseCheckService: AppReleaseChecking {
    private let catalog: AppReleaseCatalogSource
    private let sources: [any AppReleaseSourcing]
    private let installedCaskTokens: @Sendable () -> Set<String>
    private let osVersion: OperatingSystemVersion

    /// - Parameters:
    ///   - catalog: Consulted first; apps it covers are not sent to the plain
    ///     Sparkle source, so one feed is never fetched twice.
    ///   - sources: The automatic sources (Sparkle, Homebrew, App Store).
    public init(
        catalog: AppReleaseCatalogSource,
        sources: [any AppReleaseSourcing],
        installedCaskTokens: @escaping @Sendable () -> Set<String> = { HomebrewCaskroomProbe().installedTokens() },
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.catalog = catalog
        self.sources = sources
        self.installedCaskTokens = installedCaskTokens
        self.osVersion = osVersion
    }

    /// Production wiring: one https-only client shared by every source.
    public static func makeDefault(http: any AppReleaseHTTPFetching = DefaultAppReleaseHTTPClient()) -> AppReleaseCheckService {
        let sparkle = SparkleAppcastSource(http: http)
        return AppReleaseCheckService(
            catalog: AppReleaseCatalogSource(http: http, sparkle: sparkle),
            sources: [
                sparkle,
                HomebrewCaskSource(index: HomebrewCaskIndex(http: http)),
                MASLookupSource(http: http),
            ]
        )
    }

    public func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
        let candidates = apps.filter { !preferences.ignoredBundleIDs.contains($0.bundleID) }
        let covered = catalog.coveredBundleIDs
        let catalog = self.catalog
        let sources = self.sources

        let byKind = await withTaskGroup(of: (AppReleaseSourceKind, [String: AppReleaseSourceOutcome]).self) { group in
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

        let caskroom = installedCaskTokens()
        return apps.map { app in
            var outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [:]
            for (kind, results) in byKind {
                if let outcome = results[app.bundleID] { outcomes[kind] = outcome }
            }
            return AppReleaseResolver.resolve(
                app: app,
                outcomes: outcomes,
                brewManagedToken: Self.brewManagedToken(outcomes[.homebrewCask], caskroom: caskroom),
                preferences: preferences,
                osVersion: osVersion
            )
        }
    }

    /// The cask token when the app matched a cask that brew has installed.
    static func brewManagedToken(_ outcome: AppReleaseSourceOutcome?, caskroom: Set<String>) -> String? {
        guard case .found(let candidate) = outcome, let token = candidate.caskToken, caskroom.contains(token) else {
            return nil
        }
        return token
    }
}
