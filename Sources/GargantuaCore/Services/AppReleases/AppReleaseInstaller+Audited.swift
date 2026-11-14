import Foundation

/// One line of an install's audit record: what ran and which files it touched.
struct AppReleaseAuditLine {
    let command: String
    let files: [AuditFile]
    var exitCode: Int32?
}

/// An install step that failed after its intent was recorded, with the line
/// saying what it left behind.
struct AppReleaseStepFailure: Error {
    let error: AppReleaseInstallError
    let line: AppReleaseAuditLine
}

/// How one install is audited and reported.
struct AppReleaseAuditPlan {
    /// The intent line's command.
    let summary: String
    /// brew's arguments for a Homebrew upgrade, recorded as a command entry.
    /// Nil for an in-place swap, recorded as a Trash entry.
    let brewArguments: [String]?
    /// Thrown, with nothing run, when the intent line can't be written.
    let unrecorded: AppReleaseInstallError
    /// Progress phase while the step runs.
    let phase: AppReleaseInstallPhase

    /// Every audit line of the install, so the intent and outcome lines
    /// share one shape and ID.
    func entry(id: UUID, _ line: AppReleaseAuditLine, status: AuditEntryStatus) -> AuditEntry {
        AuditEntry(
            id: id,
            tool: AppReleaseInstaller.auditTool,
            command: line.command,
            files: line.files,
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            cleanupMethod: brewArguments == nil ? .trash : .toolNative,
            bytesFreed: 0,
            kind: brewArguments == nil ? .path : .command,
            commandExitCode: line.exitCode,
            commandArguments: brewArguments,
            status: status
        )
    }
}

extension AppReleaseInstaller {
    /// Quits the app if it's running (only with consent), records the
    /// intent, runs `step`, records the outcome, and reopens the app if this
    /// flow quit it. Shared by the in-place swap and the brew upgrade. A
    /// surviving `.attempted` line means the process died mid-step.
    @MainActor
    func runAudited<Value>(
        app: InstalledApp,
        quitIfRunning: Bool,
        plan: AppReleaseAuditPlan,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void,
        step: @MainActor () async throws(AppReleaseStepFailure) -> (Value, AppReleaseAuditLine)
    ) async throws(AppReleaseInstallError) -> (value: Value, relaunched: Bool) {
        let wasRunning = try await quitIfNeeded(bundleID: app.bundleID, consent: quitIfRunning, progress: progress)
        let id = UUID()

        do {
            let intent = AppReleaseAuditLine(command: plan.summary, files: [AuditFile(path: app.url.path, size: 0)])
            try auditRecorder.write(plan.entry(id: id, intent, status: .attempted))
        } catch {
            appReleaseInstallLogger.error("App update intent audit failed: \(error.localizedDescription, privacy: .public)")
            await relaunchIfNeeded(app.url, wasRunning: wasRunning)
            throw plan.unrecorded
        }

        progress(plan.phase)
        let value: Value
        let outcome: AppReleaseAuditLine
        do throws(AppReleaseStepFailure) {
            (value, outcome) = try await step()
        } catch {
            try? auditRecorder.write(plan.entry(id: id, error.line, status: .completed))
            await relaunchIfNeeded(app.url, wasRunning: wasRunning)
            throw error.error
        }

        do {
            try auditRecorder.write(plan.entry(id: id, outcome, status: .completed))
        } catch {
            appReleaseInstallLogger.error("App update audit failed after the change: \(error.localizedDescription, privacy: .public)")
        }
        let relaunched = await relaunchAfterSuccess(app.url, wasRunning: wasRunning, progress: progress)
        return (value, relaunched)
    }

    /// Returns whether the app was running and has now quit.
    @MainActor
    func quitIfNeeded(
        bundleID: String,
        consent: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async throws(AppReleaseInstallError) -> Bool {
        guard quitter.isRunning(bundleID: bundleID) else { return false }
        guard consent else { throw .stillRunning }
        progress(.quitting)
        guard await quitter.quitGracefully(bundleID: bundleID, timeout: Self.quitTimeout) else {
            throw .stillRunning
        }
        return true
    }

    @MainActor
    func relaunchAfterSuccess(
        _ url: URL,
        wasRunning: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Bool {
        guard wasRunning else { return false }
        progress(.relaunching)
        return await quitter.relaunch(at: url)
    }

    /// Reopens an app this flow quit when the install stopped short, as long
    /// as a bundle is still at its path.
    @MainActor
    func relaunchIfNeeded(_ url: URL, wasRunning: Bool) async {
        guard wasRunning, AppBundleFiles.fileType(atPath: url.path) != nil else { return }
        _ = await quitter.relaunch(at: url)
    }
}
