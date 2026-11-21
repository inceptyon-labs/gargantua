import Foundation

extension AppReleaseInstaller {
    typealias BrewUpgrade = (version: AppReleaseVersion, warning: String?)

    @MainActor
    func upgradeWithHomebrew(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        token: String,
        quitIfRunning: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async throws(AppReleaseInstallError) -> AppReleaseInstallResult {
        guard Self.isPlausibleCaskToken(token) else { throw .notInstallable }
        guard let brew = brewLocator() else { throw .brewUnavailable }
        let before = AppBundleFiles.bundleVersion(at: app.url) ?? app.version
        // Checked again before brew runs; this one only saves a download
        // that couldn't be installed.
        if !quitIfRunning, quitter.isRunning(bundleID: app.bundleID) { throw .stillRunning }
        switch try await brewPreflight(brew, token: token, app: app, candidate: candidate, before: before, progress: progress) {
        case .proceed:
            break
        case .notNewer(let staged, isOfferedRelease: true):
            throw .verification(.notNewer(staged: staged, installed: before))
        case .notNewer(let staged, isOfferedRelease: false):
            throw .brewDownloadNotNewer(staged: staged, installed: before)
        }
        let arguments = ["upgrade", "--cask", "--greedy", token]
        let summary = "brew upgrade \(app.bundleID) \(before) → \(candidate.displayVersion)"
        let plan = AppReleaseAuditPlan(
            summary: summary,
            brewArguments: arguments,
            unrecorded: .brewFailed("The audit log couldn't record the upgrade, so it wasn't run."),
            phase: .upgradingWithHomebrew
        )

        let (upgrade, relaunched) = try await runAudited(
            app: app,
            quitIfRunning: quitIfRunning,
            plan: plan,
            progress: progress
        ) { () async throws(AppReleaseStepFailure) -> (BrewUpgrade, AppReleaseAuditLine) in
            try await runBrew(brew, arguments: arguments, app: app, before: before, summary: summary)
        }
        return AppReleaseInstallResult(
            installedVersion: upgrade.version,
            previousCopyInTrash: nil,
            relaunched: relaunched,
            warning: upgrade.warning
        )
    }

    /// Runs brew off the main actor, then judges the upgrade by the bundle's
    /// Info.plist on disk rather than brew's output. Brew doesn't check the
    /// new copy's signer, so a Team ID that changed comes back as a warning.
    private func runBrew(
        _ brew: URL,
        arguments: [String],
        app: InstalledApp,
        before: AppReleaseVersion,
        summary: String
    ) async throws(AppReleaseStepFailure) -> (BrewUpgrade, AppReleaseAuditLine) {
        let files = [AuditFile(path: app.url.path, size: 0)]
        func failure(_ error: AppReleaseInstallError, _ note: String, exitCode: Int32?) -> AppReleaseStepFailure {
            AppReleaseStepFailure(
                error: error,
                line: AppReleaseAuditLine(command: "\(summary) (\(note))", files: files, exitCode: exitCode)
            )
        }

        let output: ProcessOutput
        do {
            output = try await runDetached(brew, arguments).get()
        } catch {
            throw failure(.brewFailed(error.localizedDescription), "failed to run", exitCode: nil)
        }
        guard output.exitCode == 0 else {
            throw failure(.brewFailed(Self.lastLines(of: output)), "failed", exitCode: output.exitCode)
        }
        guard let after = AppBundleFiles.bundleVersion(at: app.url), after.isNewer(than: before) else {
            throw failure(.brewNoChange, "no version change", exitCode: 0)
        }
        let warning = Self.teamChangeWarning(installed: app.teamID, upgraded: teamIDReader(app.url))
        var command = "brew upgrade \(app.bundleID) \(before) → \(after)"
        if let warning { command += " (warning: \(warning))" }
        return ((after, warning), AppReleaseAuditLine(command: command, files: files, exitCode: 0))
    }

    static func teamChangeWarning(installed: String?, upgraded: String?) -> String? {
        guard upgraded != installed else { return nil }
        return "The new copy is signed by a different developer (\(upgraded ?? "none")) "
            + "than the copy it replaced (\(installed ?? "none"))."
    }

    /// A token is passed to brew as an argument, so one that could read as an
    /// option is refused, and so is a tap-qualified `user/tap/name`, which
    /// would point brew at another tap.
    static func isPlausibleCaskToken(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-@._+"))
        return token.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    static func lastLines(of output: ProcessOutput) -> String {
        let source = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? output.stdout : output.stderr
        let lines = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(5)
        return lines.isEmpty ? "brew exited with status \(output.exitCode)." : lines.joined(separator: "\n")
    }
}
