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
        var eligible = found.filter { !$0.isPrerelease && runs(on: osVersion, minimum: $0.minimumSystemVersion) }
        if brewManagedToken == nil, let ceiling = vendorCeiling(considered, installed: app.version) {
            eligible = eligible.filter { $0.version.compare(to: ceiling) != .orderedDescending }
        }
        let newer = eligible.filter { $0.version.isNewer(than: app.version) }

        guard let chosen = preferred(among: newer) else {
            return row(noUpdateStatus(considered: considered, eligible: eligible))
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

    /// Nothing newer: the newest eligible release, or why there is none.
    private static func noUpdateStatus(
        considered: [AppReleaseSourceKind: AppReleaseSourceOutcome],
        eligible: [AppReleaseCandidate]
    ) -> AppReleaseStatus {
        if let latest = preferred(among: eligible) { return .upToDate(latest: latest) }
        if considered.isEmpty { return .untracked }
        let failures = considered.values.compactMap { outcome -> String? in
            if case .failed(let message) = outcome { return message }
            return nil
        }
        if failures.count == considered.count, let first = failures.first { return .failed(first) }
        return .upToDate(latest: nil)
    }

    /// The highest version the vendor's own feed (or a curated catalog
    /// entry) offers this copy. Another source may supply the download for
    /// that version but never a higher one: a vendor feed that stops at 15.x
    /// while Homebrew lists 16.0 usually means 16 is a paid upgrade.
    /// Nil when neither answered.
    static func vendorCeiling(
        _ outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome],
        installed: AppReleaseVersion
    ) -> AppReleaseVersion? {
        var answered = false
        var best: AppReleaseVersion?
        for kind in [AppReleaseSourceKind.catalog, .sparkle] {
            switch outcomes[kind] {
            case .found(let candidate):
                answered = true
                if best.map({ candidate.version.compare(to: $0) == .orderedDescending }) ?? true {
                    best = candidate.version
                }
            case .noEligibleRelease:
                answered = true
            case .failed, nil:
                continue
            }
        }
        guard answered else { return nil }
        guard let best else { return installed }
        return best.compare(to: installed) == .orderedAscending ? installed : best
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

    /// An unparsable minimum doesn't hide a release; install verification
    /// checks the downloaded bundle's own LSMinimumSystemVersion.
    static func runs(on osVersion: OperatingSystemVersion, minimum: String?) -> Bool {
        guard let minimum else { return true }
        return osVersion.meets(minimum: minimum) ?? true
    }
}
