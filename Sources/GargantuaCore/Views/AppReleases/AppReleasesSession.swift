import Foundation
import GargantuaLicensing
import SwiftUI

/// Where the App Updates page is: nothing checked yet, a check running, a
/// list on screen, or a check that produced nothing.
public enum AppReleasesPhase: Equatable, Sendable {
    case idle
    case checking
    case ready
    case failed(String)
}

/// Which rows the list shows.
public enum AppReleasesFilter: String, CaseIterable, Sendable {
    case updates
    case all
    case ignored

    var label: String {
        switch self {
        case .updates: "Updates"
        case .all: "All"
        case .ignored: "Ignored"
        }
    }
}

/// What the last install attempt on a row left behind.
public enum AppReleaseRowMessage: Equatable, Sendable {
    case installed(String)
    /// Installed, but with something the user should look at.
    case installedWithWarning(String)
    case failed(String)
}

/// Holds the App Updates list, the user's ignore and skip choices, and the
/// state of any install in flight. The window keeps one for its lifetime so
/// the list survives navigating away.
@MainActor
@Observable
public final class AppReleasesSession {
    public private(set) var rows: [AppReleaseRow] = []
    public private(set) var phase: AppReleasesPhase = .idle
    public private(set) var lastChecked: Date?
    /// Bundle IDs with an install running, and where each one is.
    public private(set) var installPhases: [String: AppReleaseInstallPhase] = [:]
    public private(set) var rowMessages: [String: AppReleaseRowMessage] = [:]
    /// Rows updated this visit. They stay in the Updates filter, with their
    /// message, until the next check or until the user leaves the pane.
    public private(set) var recentlyInstalled: Set<String> = []
    public private(set) var preferences: AppReleasePreferences
    public var filter: AppReleasesFilter = .updates
    public var query = ""
    /// Drives the shared Unlock sheet when the license gate refuses an install.
    public var blockedReason: BlockReason?
    /// Set when macOS refused to let Gargantua replace another developer's app.
    public var showsAppManagementHelp = false

    @ObservationIgnored private let inventory: any AppReleaseInventoryProviding
    @ObservationIgnored private let checker: any AppReleaseChecking
    @ObservationIgnored private let installer: any AppReleaseInstalling
    @ObservationIgnored private let authorize: @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult
    @ObservationIgnored private let quitter: any AppReleaseAppQuitting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    /// Bumped by every check and by Cancel, so a superseded run drops its result.
    @ObservationIgnored private var checkGeneration = 0
    @ObservationIgnored private var phaseBeforeCheck: AppReleasesPhase = .idle
    /// Apps with an install that began or was running since the current check
    /// started. That check may have read their old version, so its rows for
    /// them are discarded.
    @ObservationIgnored private var installedDuringCheck: Set<String> = []

    public init(
        inventory: any AppReleaseInventoryProviding,
        checker: any AppReleaseChecking,
        installer: any AppReleaseInstalling,
        authorize: @escaping @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult = {
            await LicenseGate.shared.authorize($0)
        },
        quitter: any AppReleaseAppQuitting = WorkspaceAppReleaseQuitter(),
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        self.inventory = inventory
        self.checker = checker
        self.installer = installer
        self.authorize = authorize
        self.quitter = quitter
        self.now = now
        self.defaults = defaults
        self.preferences = AppReleasePreferences.stored(in: defaults)
    }

    /// The production session: real inventory, sources and installer.
    public convenience init() {
        self.init(
            inventory: DefaultAppReleaseInventory(),
            checker: AppReleaseCheckService.makeDefault(),
            installer: AppReleaseInstaller()
        )
    }

    // MARK: - Derived

    public var availableCount: Int {
        rows.filter { $0.availableCandidate != nil }.count
    }

    /// False after `releaseResults()` empties the list.
    public var hasResults: Bool { !rows.isEmpty }

    public var isChecking: Bool { phase == .checking }

    /// Apps the last check could not reach any source for.
    public var failedCount: Int {
        rows.filter { if case .failed = $0.status { true } else { false } }.count
    }

    /// Rows for the current filter and search, updates first, then by name.
    public var visibleRows: [AppReleaseRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows
            .filter { matches($0, filter: filter) }
            .filter { needle.isEmpty || $0.app.name.lowercased().contains(needle) || $0.app.bundleID.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                let (l, r) = (isPinned(lhs), isPinned(rhs))
                if l != r { return l }
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            }
    }

    public func count(for filter: AppReleasesFilter) -> Int {
        rows.filter { matches($0, filter: filter) }.count
    }

    private func isPinned(_ row: AppReleaseRow) -> Bool {
        row.availableCandidate != nil || recentlyInstalled.contains(row.id)
    }

    private func matches(_ row: AppReleaseRow, filter: AppReleasesFilter) -> Bool {
        switch (filter, row.status) {
        case (.updates, .available): true
        case (.updates, _): recentlyInstalled.contains(row.id)
        case (.ignored, .ignored), (.ignored, .skippedVersion): true
        case (.ignored, _): false
        case (.all, .ignored), (.all, .skippedVersion): false
        case (.all, _): true
        }
    }

    // MARK: - Checking

    /// Starts a check. One already running is joined, not replaced: the call
    /// is ignored, and Cancel is what stops it.
    public func startCheck(isAutomatic: Bool = false) {
        guard activeTask == nil else { return }
        activeTask = Task { [weak self] in
            await self?.check(isAutomatic: isAutomatic)
            if let self, !Task.isCancelled { activeTask = nil }
        }
    }

    public func cancelCheck() {
        guard let task = activeTask else { return }
        task.cancel()
        activeTask = nil
        checkGeneration += 1
        restorePhaseBeforeCheck()
    }

    /// Reads the installed apps, then asks every source about them. A
    /// cancelled run leaves the list as it was.
    public func check(isAutomatic: Bool = false) async {
        checkGeneration += 1
        let generation = checkGeneration
        phaseBeforeCheck = isChecking ? phaseBeforeCheck : phase
        phase = .checking
        installedDuringCheck = Set(installPhases.keys)

        let apps = await inventory.installedApps()
        guard isCurrent(generation) else { return }
        guard !apps.isEmpty else {
            phase = .failed("Gargantua couldn't find any installed apps to check.")
            return
        }
        let result = await checker.check(apps, preferences: preferences)
        guard isCurrent(generation) else { return }

        let protected = installedDuringCheck
        let current = preferences
        rows = result.compactMap { row in
            protected.contains(row.id) ? rows.first { $0.id == row.id } : Self.applying(current, to: row)
        }
        recentlyInstalled.formIntersection(protected)
        rowMessages = rowMessages.filter { id, message in
            if case .installed = message { return protected.contains(id) }
            return true
        }
        lastChecked = now()
        phase = .ready
        storeAvailableCount()
        if isAutomatic {
            updatePreferences { $0.lastAutoCheck = lastChecked }
        }
        // An ignore or skip lifted while the check ran left stale rows.
        let staleApps = rows
            .filter { !protected.contains($0.id) && Self.isStale($0, under: preferences) }
            .map(\.app)
        for app in staleApps { await refresh(app) }
    }

    /// True when the row shows an ignore or skip the preferences no longer hold.
    static func isStale(_ row: AppReleaseRow, under preferences: AppReleasePreferences) -> Bool {
        switch row.status {
        case .ignored: return !preferences.ignoredBundleIDs.contains(row.id)
        case .skippedVersion(let version): return preferences.skippedVersions[row.id] != version
        default: return false
        }
    }

    /// The checker saw the preferences from when the check started; an app
    /// ignored or a version skipped while it ran stays that way.
    private static func applying(_ preferences: AppReleasePreferences, to row: AppReleaseRow) -> AppReleaseRow {
        if preferences.ignoredBundleIDs.contains(row.id) {
            return AppReleaseRow(app: row.app, status: .ignored, sources: row.sources)
        }
        if let candidate = row.availableCandidate, preferences.skippedVersions[row.id] == candidate.displayVersion {
            return AppReleaseRow(app: row.app, status: .skippedVersion(candidate.displayVersion), sources: row.sources)
        }
        return row
    }

    /// False once a newer check or Cancel superseded this one; a cancelled
    /// run that nothing else replaced puts the phase back.
    private func isCurrent(_ generation: Int) -> Bool {
        guard generation == checkGeneration else { return false }
        if Task.isCancelled {
            restorePhaseBeforeCheck()
            return false
        }
        return true
    }

    private func restorePhaseBeforeCheck() {
        guard phase == .checking else { return }
        phase = phaseBeforeCheck == .checking ? .idle : phaseBeforeCheck
    }

    /// The opt-in daily check. Does nothing unless the Settings toggle is on
    /// and a day has passed since the last automatic run. It runs on the same
    /// cancellable path as a manual check.
    public func checkIfAutoDue() async {
        guard activeTask == nil, phase != .checking, installPhases.isEmpty else { return }
        guard AppReleasePreferences.stored(in: defaults).isAutoCheckDue(now: now()) else { return }
        startCheck(isAutomatic: true)
        await activeTask?.value
    }

    /// Forgets this visit's finished installs once the user leaves the pane.
    public func paneDidDisappear() {
        recentlyInstalled = []
        rowMessages = rowMessages.filter { if case .installed = $0.value { false } else { true } }
    }

    /// Drops the list; used under memory pressure.
    public func releaseResults() {
        guard phase != .checking, installPhases.isEmpty else { return }
        rows = []
        rowMessages = [:]
        recentlyInstalled = []
        if phase == .ready { phase = .idle }
    }

    // MARK: - Installing

    /// Whether updating this row first needs the user's consent to quit the app.
    public func requiresQuitConsent(_ row: AppReleaseRow) -> Bool {
        row.app.isRunning || quitter.isRunning(bundleID: row.app.bundleID)
    }

    /// Installs the row's update. The license gate runs first. A running app
    /// is never touched without `quitIfRunning`.
    public func install(_ row: AppReleaseRow, quitIfRunning: Bool) async {
        guard case .available(let candidate, let strategy) = row.status, strategy.isDestructive else { return }
        let id = row.app.bundleID
        guard installPhases[id] == nil else { return }

        // Claimed before the first await so a second tap can't start another.
        if case .brewUpgrade = strategy {
            installPhases[id] = .upgradingWithHomebrew
        } else {
            installPhases[id] = .downloading
        }
        installedDuringCheck.insert(id)
        defer { installPhases[id] = nil }

        let authorization: DestructiveActionAuthorization
        switch await authorize(.appUpdater) {
        case .failure(let reason):
            blockedReason = reason
            return
        case .success(let token):
            authorization = token
        }

        if !quitIfRunning, requiresQuitConsent(row) {
            rowMessages[id] = .failed("\(row.app.name) is open. Quit it, then try again.")
            return
        }

        rowMessages[id] = nil
        let result = await installer.install(
            app: row.app,
            candidate: candidate,
            strategy: strategy,
            quitIfRunning: quitIfRunning,
            authorization: authorization,
            progress: { [weak self] phase in
                guard self?.installPhases[id] != nil else { return }
                self?.installPhases[id] = phase
            }
        )

        switch result {
        case .success(let installed):
            let updated = "Updated to \(installed.installedVersion.description)."
            // A warning stays on screen, in the failure style, until the next attempt.
            rowMessages[id] = installed.warning.map { .installedWithWarning("\(updated) \($0)") } ?? .installed(updated)
            recentlyInstalled.insert(id)
            await refresh(row.app)
        case .failure(let error):
            rowMessages[id] = .failed(error.localizedDescription)
            if error == .appManagementDenied { showsAppManagementHelp = true }
        }
    }

    /// Re-reads one app from disk and checks just that app again.
    private func refresh(_ app: InstalledApp) async {
        guard let installed = await inventory.installedApp(at: app.url) else {
            rows.removeAll { $0.id == app.bundleID }
            recentlyInstalled.remove(app.bundleID)
            storeAvailableCount()
            return
        }
        guard var fresh = await checker.check([installed], preferences: preferences).first else { return }
        fresh = Self.applying(preferences, to: fresh)
        if Self.isStale(fresh, under: preferences) {
            // A relaxation landed while the check ran; resolve once more.
            guard let again = await checker.check([installed], preferences: preferences).first else { return }
            fresh = Self.applying(preferences, to: again)
        }
        replace(fresh)
    }

    private func replace(_ row: AppReleaseRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        storeAvailableCount()
    }

    /// Keeps the count the sidebar badge and the background check read current.
    private func storeAvailableCount() {
        guard lastChecked != nil else { return }
        AppReleaseBackgroundState.storeAvailableCount(availableCount, in: defaults)
    }

    // MARK: - Ignore and skip

    public func ignore(_ bundleID: String) {
        updatePreferences { $0.ignoredBundleIDs.insert(bundleID) }
        setStatus(.ignored, for: bundleID)
    }

    public func unignore(_ bundleID: String) async {
        updatePreferences { $0.ignoredBundleIDs.remove(bundleID) }
        if let app = rows.first(where: { $0.id == bundleID })?.app { await refresh(app) }
    }

    /// Hides this exact version; a newer release shows again.
    public func skip(version: String, for bundleID: String) {
        updatePreferences { $0.skippedVersions[bundleID] = version }
        setStatus(.skippedVersion(version), for: bundleID)
    }

    public func unskip(_ bundleID: String) async {
        updatePreferences { $0.skippedVersions[bundleID] = nil }
        if let app = rows.first(where: { $0.id == bundleID })?.app { await refresh(app) }
    }

    private func setStatus(_ status: AppReleaseStatus, for bundleID: String) {
        guard let row = rows.first(where: { $0.id == bundleID }) else { return }
        replace(AppReleaseRow(app: row.app, status: status, sources: row.sources))
    }

    /// Applies a change to the stored preferences rather than this session's
    /// copy, so a toggle flipped in Settings is not overwritten.
    private func updatePreferences(_ change: (inout AppReleasePreferences) -> Void) {
        var fresh = AppReleasePreferences.stored(in: defaults)
        change(&fresh)
        fresh.store(in: defaults)
        preferences = fresh
    }
}
