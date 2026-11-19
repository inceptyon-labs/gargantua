import Foundation
import GargantuaLicensing

extension AppReleasesSession {
    /// Whether updating this row first needs the user's consent to quit the app.
    public func requiresQuitConsent(_ row: AppReleaseRow) -> Bool {
        // Asked live: the row's `isRunning` is from the last check, and the
        // app may have quit since.
        quitter.isRunning(bundleID: row.app.bundleID)
    }

    /// Installs the row's update. The license gate runs first. A running app
    /// is never touched without `quitIfRunning`.
    public func install(_ row: AppReleaseRow, quitIfRunning: Bool) async {
        guard case .available(let candidate, let strategy) = row.status, strategy.isDestructive else { return }
        guard installPhases[row.id] == nil else { return }

        // Claimed before the first await so a second tap can't start another.
        markStarting(row.id, strategy: strategy)
        await runInstall(row, candidate: candidate, strategy: strategy, quitIfRunning: quitIfRunning)
    }

    func markStarting(_ id: String, strategy: AppReleaseInstallStrategy) {
        if case .brewUpgrade = strategy {
            installPhases[id] = .upgradingWithHomebrew
        } else {
            installPhases[id] = .downloading(received: 0, expected: nil)
        }
        installedDuringCheck.insert(id)
    }

    /// Runs an install whose row `markStarting` already claimed.
    @discardableResult
    func runInstall(
        _ row: AppReleaseRow,
        candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy,
        quitIfRunning: Bool
    ) async -> AppReleaseInstallAttempt {
        let id = row.app.bundleID
        defer { installPhases[id] = nil }

        let authorization: DestructiveActionAuthorization
        switch await authorize(.appUpdater) {
        case .failure(let reason):
            blockedReason = reason
            return .blocked
        case .success(let token):
            authorization = token
        }

        if !quitIfRunning, requiresQuitConsent(row) {
            rowMessages[id] = .failed("\(row.app.name) is open. Quit it, then try again.")
            return .failed
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

        return await finish(result, of: candidate, for: row)
    }

    /// Stores the user's approval of `change` for the app, then installs the
    /// update its row offers now.
    public func approveSigner(_ change: AppReleaseSignerChange, for bundleID: String, quitIfRunning: Bool) async {
        updatePreferences { $0.approve(change, for: bundleID) }
        guard let row = rows.first(where: { $0.id == bundleID }) else { return }
        await install(row, quitIfRunning: quitIfRunning)
    }

    /// Shows what an install attempt left behind and re-checks the app.
    private func finish(
        _ result: Result<AppReleaseInstallResult, AppReleaseInstallError>,
        of candidate: AppReleaseCandidate,
        for row: AppReleaseRow
    ) async -> AppReleaseInstallAttempt {
        let id = row.app.bundleID
        let attempt: AppReleaseInstallAttempt
        switch result {
        case .success(let installed):
            let updated = "Updated to \(installed.installedVersion.description)."
            // A warning stays on screen, in the failure style, until the next attempt.
            rowMessages[id] = installed.warning.map { .installedWithWarning("\(updated) \($0)") } ?? .installed(updated)
            updatePreferences { $0.confirm(candidate, holds: installed.installedVersion.description, for: id) }
            attempt = .updated
        case .failure(let error):
            if case .signerChanged(let change) = error {
                rowMessages[id] = .signerChanged(change)
                return .failed
            }
            guard let current = error.versionAlreadyInstalled else {
                rowMessages[id] = .failed(error.localizedDescription)
                guard error == .appManagementDenied else { return .failed }
                showsAppManagementHelp = true
                return .denied
            }
            // The download holds the installed version; its source only names it differently.
            rowMessages[id] = .installed("Already up to date. This release is the version that's installed.")
            updatePreferences { $0.confirm(candidate, holds: current, for: id) }
            attempt = .alreadyCurrent
        }
        recentlyInstalled.insert(id)
        await refresh(row.app)
        return attempt
    }
}
