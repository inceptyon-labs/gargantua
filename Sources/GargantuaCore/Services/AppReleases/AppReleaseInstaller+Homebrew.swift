import Foundation

extension AppReleaseInstaller {
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
        let arguments = ["upgrade", "--cask", "--greedy", token]
        let summary = "brew upgrade \(app.bundleID) \(before) → \(candidate.displayVersion)"
        let plan = AppReleaseAuditPlan(
            summary: summary,
            brewArguments: arguments,
            unrecorded: .brewFailed("The audit log couldn't record the upgrade, so it wasn't run."),
            phase: .upgradingWithHomebrew
        )

        let (after, relaunched) = try await runAudited(
            app: app,
            quitIfRunning: quitIfRunning,
            plan: plan,
            progress: progress
        ) { () async throws(AppReleaseStepFailure) -> (AppReleaseVersion, AppReleaseAuditLine) in
            try await runBrew(brew, arguments: arguments, app: app, before: before, summary: summary)
        }
        return AppReleaseInstallResult(installedVersion: after, previousCopyInTrash: nil, relaunched: relaunched)
    }

    /// Runs brew off the main actor, then judges the upgrade by the bundle's
    /// Info.plist on disk rather than brew's output.
    private func runBrew(
        _ brew: URL,
        arguments: [String],
        app: InstalledApp,
        before: AppReleaseVersion,
        summary: String
    ) async throws(AppReleaseStepFailure) -> (AppReleaseVersion, AppReleaseAuditLine) {
        let files = [AuditFile(path: app.url.path, size: 0)]
        func failure(_ error: AppReleaseInstallError, _ note: String, exitCode: Int32?) -> AppReleaseStepFailure {
            AppReleaseStepFailure(
                error: error,
                line: AppReleaseAuditLine(command: "\(summary) (\(note))", files: files, exitCode: exitCode)
            )
        }

        let runner = runner
        let outcome = await Task.detached(priority: .userInitiated) {
            Result {
                try runner.run(
                    executable: brew,
                    arguments: arguments,
                    timeout: Self.brewTimeout,
                    maxCapturedBytes: Self.brewCaptureBytes
                )
            }
        }.value

        let output: ProcessOutput
        do {
            output = try outcome.get()
        } catch {
            throw failure(.brewFailed(error.localizedDescription), "failed to run", exitCode: nil)
        }
        guard output.exitCode == 0 else {
            throw failure(.brewFailed(Self.lastLines(of: output)), "failed", exitCode: output.exitCode)
        }
        guard let after = AppBundleFiles.bundleVersion(at: app.url), after.isNewer(than: before) else {
            throw failure(.brewNoChange, "no version change", exitCode: 0)
        }
        let line = AppReleaseAuditLine(command: "brew upgrade \(app.bundleID) \(before) → \(after)", files: files, exitCode: 0)
        return (after, line)
    }

    /// A token is passed to brew as an argument, so one that could read as an
    /// option is refused.
    static func isPlausibleCaskToken(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-@._+/"))
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
