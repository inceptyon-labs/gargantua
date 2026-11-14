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
    @ObservationIgnored private let isAppRunning: @MainActor (String) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    public init(
        inventory: any AppReleaseInventoryProviding,
        checker: any AppReleaseChecking,
        installer: any AppReleaseInstalling,
        authorize: @escaping @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult = {
            await LicenseGate.shared.authorize($0)
        },
        isAppRunning: @escaping @MainActor (String) -> Bool = {
            WorkspaceAppReleaseQuitter().isRunning(bundleID: $0)
        },
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        self.inventory = inventory
        self.checker = checker
        self.installer = installer
        self.authorize = authorize
        self.isAppRunning = isAppRunning
        self.now = now
        self.defaults = defaults
        self.preferences = AppReleasePreferences.stored(in: defaults)
    }

    // MARK: - Derived

    public var availableCount: Int {
        rows.filter { $0.availableCandidate != nil }.count
    }

    public var isChecking: Bool { phase == .checking }

    /// Rows for the current filter and search, updates first, then by name.
    public var visibleRows: [AppReleaseRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows
            .filter { matches($0, filter: filter) }
            .filter { needle.isEmpty || $0.app.name.lowercased().contains(needle) || $0.app.bundleID.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.availableCandidate != nil, rhs.availableCandidate != nil)
                if l != r { return l }
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            }
    }

    public func count(for filter: AppReleasesFilter) -> Int {
        rows.filter { matches($0, filter: filter) }.count
    }

    private func matches(_ row: AppReleaseRow, filter: AppReleasesFilter) -> Bool {
        switch (filter, row.status) {
        case (.updates, .available): true
        case (.updates, _): false
        case (.ignored, .ignored), (.ignored, .skippedVersion): true
        case (.ignored, _): false
        case (.all, .ignored), (.all, .skippedVersion): false
        case (.all, _): true
        }
    }

    // MARK: - Checking

    /// Starts a check, replacing one already running.
    public func startCheck() {
        activeTask?.cancel()
        activeTask = Task { await check() }
    }

    public func cancelCheck() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// Reads the installed apps, then asks every source about them. A
    /// cancelled run leaves the list as it was.
    public func check(isAutomatic: Bool = false) async {
        let previous = phase
        phase = .checking
        let apps = await inventory.installedApps()
        guard !Task.isCancelled else { return restore(previous) }
        guard !apps.isEmpty else {
            phase = .failed("Gargantua couldn't find any installed apps to check.")
            return
        }
        let result = await checker.check(apps, preferences: preferences)
        guard !Task.isCancelled else { return restore(previous) }
        rows = result
        lastChecked = now()
        phase = .ready
        if isAutomatic {
            updatePreferences { $0.lastAutoCheck = lastChecked }
        }
    }

    private func restore(_ previous: AppReleasesPhase) {
        phase = previous == .checking ? .idle : previous
    }

    /// The opt-in daily check. Does nothing unless the Settings toggle is on
    /// and a day has passed since the last automatic run.
    public func checkIfAutoDue() async {
        guard phase != .checking, installPhases.isEmpty else { return }
        guard AppReleasePreferences.stored(in: defaults).isAutoCheckDue(now: now()) else { return }
        await check(isAutomatic: true)
    }

    /// Drops the list; used under memory pressure.
    public func releaseResults() {
        guard phase != .checking, installPhases.isEmpty else { return }
        rows = []
        rowMessages = [:]
        if phase == .ready { phase = .idle }
    }

    // MARK: - Installing

    /// Whether updating this row first needs the user's consent to quit the app.
    public func requiresQuitConsent(_ row: AppReleaseRow) -> Bool {
        row.app.isRunning || isAppRunning(row.app.bundleID)
    }

    /// Installs the row's update. The license gate runs first. A running app
    /// is never touched without `quitIfRunning`.
    public func install(_ row: AppReleaseRow, quitIfRunning: Bool) async {
        guard case .available(let candidate, let strategy) = row.status, strategy.isDestructive else { return }
        let id = row.app.bundleID
        guard installPhases[id] == nil else { return }

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
        if case .brewUpgrade = strategy {
            installPhases[id] = .upgradingWithHomebrew
        } else {
            installPhases[id] = .downloading
        }
        let result = await installer.install(
            app: row.app,
            candidate: candidate,
            strategy: strategy,
            quitIfRunning: quitIfRunning,
            authorization: authorization,
            progress: { [weak self] phase in self?.installPhases[id] = phase }
        )
        installPhases[id] = nil

        switch result {
        case .success(let installed):
            rowMessages[id] = .installed("Updated to \(installed.installedVersion.description).")
            await refresh(bundleID: id)
        case .failure(let error):
            rowMessages[id] = .failed(error.localizedDescription)
            if error == .appManagementDenied { showsAppManagementHelp = true }
        }
    }

    /// Re-reads one app from disk and checks it again.
    private func refresh(bundleID: String) async {
        let apps = await inventory.installedApps()
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            rows.removeAll { $0.id == bundleID }
            return
        }
        guard let fresh = await checker.check([app], preferences: preferences).first else { return }
        replace(fresh)
    }

    private func replace(_ row: AppReleaseRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    // MARK: - Ignore and skip

    public func ignore(_ bundleID: String) {
        updatePreferences { $0.ignoredBundleIDs.insert(bundleID) }
        setStatus(.ignored, for: bundleID)
    }

    public func unignore(_ bundleID: String) async {
        updatePreferences { $0.ignoredBundleIDs.remove(bundleID) }
        await refresh(bundleID: bundleID)
    }

    /// Hides this exact version; a newer release shows again.
    public func skip(version: String, for bundleID: String) {
        updatePreferences { $0.skippedVersions[bundleID] = version }
        setStatus(.skippedVersion(version), for: bundleID)
    }

    public func unskip(_ bundleID: String) async {
        updatePreferences { $0.skippedVersions[bundleID] = nil }
        await refresh(bundleID: bundleID)
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
