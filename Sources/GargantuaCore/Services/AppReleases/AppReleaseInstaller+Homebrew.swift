import Foundation

/// Why a `brew upgrade` didn't produce a newer bundle, with what the audit
/// outcome line should say.
private struct BrewUpgradeFailure: Error {
    let error: AppReleaseInstallError
    let note: String
    let exitCode: Int32?
}

extension AppReleaseInstaller {
    @MainActor
    func upgradeWithHomebrew(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        token: String,
        quitIfRunning: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
        guard Self.isPlausibleCaskToken(token) else { return .failure(.notInstallable) }
        guard let brew = brewLocator() else { return .failure(.brewUnavailable) }
        let before = AppReleaseVerifier.bundleVersion(at: app.url) ?? app.version

        let wasRunning: Bool
        switch await quitIfNeeded(bundleID: app.bundleID, consent: quitIfRunning, progress: progress) {
        case .success(let quit): wasRunning = quit
        case .failure(let error): return .failure(error)
        }

        let arguments = ["upgrade", "--cask", "--greedy", token]
        let auditID = UUID()
        let summary = "brew upgrade \(app.bundleID) \(before) → \(candidate.displayVersion)"
        func auditEntry(_ command: String, exitCode: Int32?, status: AuditEntryStatus) -> AuditEntry {
            AuditEntry(
                id: auditID,
                tool: Self.auditTool,
                command: command,
                files: [AuditFile(path: app.url.path, size: 0)],
                safetyLevel: .review,
                confirmationMethod: .summaryDialog,
                cleanupMethod: .toolNative,
                bytesFreed: 0,
                kind: .command,
                commandExitCode: exitCode,
                commandArguments: arguments,
                status: status
            )
        }

        do {
            try auditRecorder.write(auditEntry(summary, exitCode: nil, status: .attempted))
        } catch {
            appReleaseInstallLogger.error("brew upgrade intent audit failed: \(error.localizedDescription, privacy: .public)")
            await relaunchIfNeeded(app.url, wasRunning: wasRunning)
            return .failure(.brewFailed("The audit log couldn't record the upgrade, so it wasn't run."))
        }

        progress(.upgradingWithHomebrew)
        let after: AppReleaseVersion
        switch await runBrew(brew, arguments: arguments, appURL: app.url, before: before) {
        case .success(let version):
            after = version
        case .failure(let failure):
            try? auditRecorder.write(auditEntry("\(summary) (\(failure.note))", exitCode: failure.exitCode, status: .completed))
            await relaunchIfNeeded(app.url, wasRunning: wasRunning)
            return .failure(failure.error)
        }

        do {
            try auditRecorder.write(auditEntry("brew upgrade \(app.bundleID) \(before) → \(after)", exitCode: 0, status: .completed))
        } catch {
            appReleaseInstallLogger.error("brew upgrade audit failed after upgrade: \(error.localizedDescription, privacy: .public)")
        }

        let relaunched = await relaunchAfterSuccess(app.url, wasRunning: wasRunning, progress: progress)
        return .success(AppReleaseInstallResult(installedVersion: after, previousCopyInTrash: nil, relaunched: relaunched))
    }

    /// Runs brew off the main actor, then judges the upgrade by the bundle's
    /// Info.plist on disk rather than brew's output.
    private func runBrew(
        _ brew: URL,
        arguments: [String],
        appURL: URL,
        before: AppReleaseVersion
    ) async -> Result<AppReleaseVersion, BrewUpgradeFailure> {
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
        switch outcome {
        case .success(let result):
            output = result
        case .failure(let error):
            return .failure(BrewUpgradeFailure(error: .brewFailed(error.localizedDescription), note: "failed to run", exitCode: nil))
        }
        guard output.exitCode == 0 else {
            return .failure(BrewUpgradeFailure(error: .brewFailed(Self.lastLines(of: output)), note: "failed", exitCode: output.exitCode))
        }
        guard let after = AppReleaseVerifier.bundleVersion(at: appURL), after.isNewer(than: before) else {
            return .failure(BrewUpgradeFailure(error: .brewNoChange, note: "no version change", exitCode: 0))
        }
        return .success(after)
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
