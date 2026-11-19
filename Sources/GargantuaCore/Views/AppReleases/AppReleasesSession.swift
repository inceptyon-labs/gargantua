import Foundation
import GargantuaLicensing
import SwiftUI

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
    public internal(set) var installPhases: [String: AppReleaseInstallPhase] = [:]
    public internal(set) var rowMessages: [String: AppReleaseRowMessage] = [:]
    /// Rows updated this visit. They stay in the Updates filter, with their
    /// message, until the next check or until the user leaves the pane.
    public internal(set) var recentlyInstalled: Set<String> = []
    public private(set) var preferences: AppReleasePreferences
    /// The Update All run in progress.
    public internal(set) var batch: AppReleaseBatchProgress?
    /// How the last Update All run went, until the next check or the user
    /// leaves the pane.
    public internal(set) var batchSummary: AppReleaseBatchSummary?
    public var filter: AppReleasesFilter = .updates
    public var query = ""
    /// Drives the shared Unlock sheet when the license gate refuses an install.
    public var blockedReason: BlockReason?
    /// Set when macOS refused to let Gargantua replace another developer's app.
    public var showsAppManagementHelp = false

    @ObservationIgnored private var isPaneVisible = false
    @ObservationIgnored private let inventory: any AppReleaseInventoryProviding
    @ObservationIgnored private let checker: any AppReleaseChecking
    @ObservationIgnored let installer: any AppReleaseInstalling
    @ObservationIgnored let authorize: @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult
    @ObservationIgnored let quitter: any AppReleaseAppQuitting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) var activeTask: Task<Void, Never>?
    /// Bumped by every check and by Cancel, so a superseded run drops its result.
    @ObservationIgnored private var checkGeneration = 0
    @ObservationIgnored private var phaseBeforeCheck: AppReleasesPhase = .idle
    /// Apps with an install that began or was running since the current check
    /// started. That check may have read their old version, so its rows for
    /// them are discarded.
    @ObservationIgnored var installedDuringCheck: Set<String> = []
    /// Bundle IDs still waiting in the Update All run, next one first.
    @ObservationIgnored var batchQueue: [String] = []
    /// Numbers each app's single-app re-checks, so an older one can't land
    /// after a newer one.
    @ObservationIgnored private var refreshGenerations: [String: Int] = [:]
    /// Bumped when the list is released or replaced by a full check, which
    /// drops every re-check that started before.
    @ObservationIgnored private var resultsEpoch = 0
    /// Automatic checks in a row where most sources failed.
    @ObservationIgnored private var failedAutoChecks = 0

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
    /// is ignored, and Cancel is what stops it. An Update All run has to end
    /// first, so a check can't replace the rows it is working through.
    public func startCheck(isAutomatic: Bool = false) {
        guard activeTask == nil, batch == nil else { return }
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
        batchSummary = nil
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
        let existing = rows
        resultsEpoch += 1
        rows = result.compactMap { row in
            let old = existing.first { $0.id == row.id }
            if protected.contains(row.id) { return old }
            let resolved = Self.applying(current, to: row)
            // The checker saw the old preferences; a row already re-resolved
            // under the new ones is better than this stale result.
            if Self.isStale(resolved, under: current), let old, !Self.isStale(old, under: current) { return old }
            return resolved
        }
        recentlyInstalled.formIntersection(protected)
        rowMessages = rowMessages.filter { id, message in
            if case .installed = message { return protected.contains(id) }
            return true
        }
        // An ignore or skip lifted while the check ran left stale rows.
        let staleApps = rows
            .filter { !protected.contains($0.id) && Self.isStale($0, under: preferences) }
            .map(\.app)
        for app in staleApps {
            await refresh(app, checkGeneration: generation)
            guard isCurrent(generation) else { return }
        }
        lastChecked = now()
        phase = .ready
        storeAvailableCount()
        recordClocks(raw: result, isAutomatic: isAutomatic)
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
        if let candidate = row.availableCandidate, let skipped = preferences.skippedVersions[row.id],
           candidate.matchesSkipped(skipped) {
            return AppReleaseRow(app: row.app, status: .skippedVersion(skipped), sources: row.sources)
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
        guard isAutoCheckDue else { return }
        startCheck(isAutomatic: true)
        await activeTask?.value
    }

    /// Drops the list; used under memory pressure.
    public func releaseResults() {
        guard phase != .checking, installPhases.isEmpty else { return }
        resultsEpoch += 1
        rows = []
        rowMessages = [:]
        recentlyInstalled = []
        if phase == .ready { phase = .idle }
    }

    /// Re-reads one app from disk and checks just that app again. Drops its
    /// result when a newer re-check of the app started, the results were
    /// released or replaced, or the check it belongs to was superseded.
    func refresh(_ app: InstalledApp, checkGeneration: Int? = nil) async {
        let id = app.bundleID
        let number = (refreshGenerations[id] ?? 0) + 1
        refreshGenerations[id] = number
        let epoch = resultsEpoch
        func isCurrentRefresh() -> Bool {
            refreshGenerations[id] == number && epoch == resultsEpoch && (checkGeneration.map(isCurrent) ?? true)
        }

        let found = await inventory.installedApp(at: app.url)
        guard isCurrentRefresh() else { return }
        guard let installed = found else {
            rows.removeAll { $0.id == id }
            recentlyInstalled.remove(id)
            return storeAvailableCount()
        }
        guard let first = await checker.check([installed], preferences: preferences).first, isCurrentRefresh() else { return }
        var fresh = Self.applying(preferences, to: first)
        if Self.isStale(fresh, under: preferences) {
            // A relaxation landed while the check ran; resolve once more.
            guard let again = await checker.check([installed], preferences: preferences).first, isCurrentRefresh() else { return }
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
        if isPaneVisible, lastChecked != nil { updateSeen(clock: false) }
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
        removeFromBatchQueue(bundleID)
        guard let row = rows.first(where: { $0.id == bundleID }) else { return }
        replace(AppReleaseRow(app: row.app, status: status, sources: row.sources))
    }

    /// Applies a change to the stored preferences rather than this session's
    /// copy, so a toggle flipped in Settings is not overwritten.
    func updatePreferences(_ change: (inout AppReleasePreferences) -> Void) {
        var fresh = AppReleasePreferences.stored(in: defaults)
        change(&fresh)
        fresh.store(in: defaults)
        preferences = fresh
    }
}

extension AppReleasesSession {
    private var isAutoCheckDue: Bool {
        AppReleasePreferences.stored(in: defaults).isAutoCheckDue(
            now: now(),
            lastBackgroundCheck: AppReleaseBackgroundState.stored(in: defaults).lastCheck
        )
    }

    public func paneDidAppear() {
        isPaneVisible = true
        if lastChecked != nil, !rows.isEmpty { updateSeen(clock: false) }
    }

    /// Forgets this visit's finished installs once the user leaves the pane.
    public func paneDidDisappear() {
        isPaneVisible = false
        recentlyInstalled = []
        batchSummary = nil
        rowMessages = rowMessages.filter { if case .installed = $0.value { false } else { true } }
    }

    /// Stamps the daily clocks after a check. A run where most sources failed
    /// (launched before Wi-Fi is up) leaves both alone, so the hourly loop
    /// tries again instead of tomorrow; capped like the background check's
    /// retries.
    private func recordClocks(raw: [AppReleaseRow], isAutomatic: Bool) {
        let mostlyFailed = AppReleaseBackgroundCheck.mostQueriedFailed(raw)
        if !mostlyFailed { updateSeen(clock: true) }
        guard isAutomatic else { return }
        if mostlyFailed, failedAutoChecks < AppReleaseBackgroundCheck.maxFailedRetries {
            failedAutoChecks += 1
            return
        }
        failedAutoChecks = 0
        updatePreferences { $0.lastAutoCheck = lastChecked }
    }

    /// Tells the background check what the app's check found, so it neither
    /// sweeps again within a day (`clock`) nor announces updates already shown
    /// here. Versions count as seen only while the list is on screen.
    private func updateSeen(clock: Bool) {
        let key = AppReleaseBackgroundState.inAppKey
        var seen = AppReleaseBackgroundState.stored(in: defaults, key: key)
        if clock { seen.lastCheck = lastChecked }
        if isPaneVisible {
            let ids = Set(rows.map(\.app.bundleID))
            seen.announcedVersions = seen.announcedVersions.filter { ids.contains($0.key) }
            let found = rows.compactMap { row in row.availableCandidate.map { (app: row.app, version: $0.version) } }
            AppReleaseBackgroundCheck.raise(&seen.announcedVersions, to: found)
        }
        seen.store(in: defaults, key: key)
    }
}
