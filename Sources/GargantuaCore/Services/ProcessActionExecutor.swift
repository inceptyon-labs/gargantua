import Darwin
import Foundation

/// Executes mutating actions on a `ProcessItem`. `.stop` runs SIGTERM with a
/// SIGKILL fallback after a grace window; `.removeSource` is a routing
/// decision (the actual disable/delete runs through
/// `BackgroundItemActionExecutor` from the Background Items pane).
///
/// One-shot per call, no batching — each operation records its own
/// `AuditEntry` so the JSONL log is the recovery surface.
public protocol ProcessActionExecuting: Sendable {
    @MainActor
    func stop(_ item: ProcessItem) async -> ProcessActionOutcome
    @MainActor
    func removeSource(_ item: ProcessItem) async -> ProcessActionOutcome
}

public struct DefaultProcessActionExecutor: ProcessActionExecuting {
    /// Default grace window after `SIGTERM` before checking liveness and
    /// escalating to `SIGKILL`. 500 ms is enough for cooperative shutdown
    /// (atexit handlers, async flushes) without the UI feeling stuck.
    public static let defaultTermGraceNanoseconds: UInt64 = 500_000_000
    /// Default wait after `SIGKILL` before the final liveness check. Quick
    /// — SIGKILL is delivered by the kernel and the reaper runs immediately.
    public static let defaultKillGraceNanoseconds: UInt64 = 250_000_000

    private let signaler: any ProcessSignalSending
    private let router: ProcessRemoveSourceRouter
    private let audit: AuditWriter
    private let termGraceNanoseconds: UInt64
    private let killGraceNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async -> Void

    public init(
        signaler: any ProcessSignalSending = DefaultProcessSignalSender(),
        router: ProcessRemoveSourceRouter = ProcessRemoveSourceRouter(),
        audit: AuditWriter = AuditWriter(),
        termGraceNanoseconds: UInt64 = DefaultProcessActionExecutor.defaultTermGraceNanoseconds,
        killGraceNanoseconds: UInt64 = DefaultProcessActionExecutor.defaultKillGraceNanoseconds,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.signaler = signaler
        self.router = router
        self.audit = audit
        self.termGraceNanoseconds = termGraceNanoseconds
        self.killGraceNanoseconds = killGraceNanoseconds
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Stop

    @MainActor
    public func stop(_ item: ProcessItem) async -> ProcessActionOutcome {
        if let refusal = stopRefusal(for: item) {
            return refuse(item: item, action: .stop, refusal: refusal)
        }

        // Defense against PID recycling: if the snapshot's process exited
        // between the click and the signal, signaling the recycled PID would
        // hit an unrelated process. `proc_pidinfo` is much harder to spoof
        // than the PID alone — it reports the boot-relative start time of
        // whatever process currently owns the PID. Mismatch ⇒ original gone.
        if let preStart = signaler.startTime(pid: item.pid), preStart != item.startTimeUnixSeconds {
            return record(StopAuditAttempt(
                item: item, succeeded: true, error: nil,
                signal: SIGTERM, resultCode: ESRCH, escalated: false
            ))
        }

        let term = signaler.send(SIGTERM, to: item.pid)
        // `ESRCH` on the very first SIGTERM means the process exited between
        // the snapshot and the click — treat as a success and audit it so
        // the user has evidence the click landed on a real PID at the time.
        // Recording `ESRCH` (rather than 0) keeps the audit honest: a
        // forensic reader can distinguish "signal delivered" from "target
        // was already gone."
        if term.alreadyGone {
            return record(StopAuditAttempt(
                item: item, succeeded: true, error: nil,
                signal: SIGTERM, resultCode: ESRCH, escalated: false
            ))
        }

        if !term.succeeded {
            return record(StopAuditAttempt(
                item: item, succeeded: false,
                error: errnoDescription(term.errno, signal: SIGTERM),
                signal: SIGTERM, resultCode: term.errno, escalated: false
            ))
        }

        // Wait for cooperative shutdown.
        await sleep(termGraceNanoseconds)
        if Task.isCancelled {
            return record(StopAuditAttempt(
                item: item, succeeded: false,
                error: "Stop was cancelled before SIGKILL escalation.",
                signal: SIGTERM, resultCode: ECANCELED, escalated: false
            ))
        }
        if !signaler.isAlive(pid: item.pid) {
            return record(StopAuditAttempt(
                item: item, succeeded: true, error: nil,
                signal: SIGTERM, resultCode: 0, escalated: false
            ))
        }
        // Re-verify identity before escalating: if PID was recycled during
        // the grace window, the SIGKILL would land on a stranger.
        if let postStart = signaler.startTime(pid: item.pid), postStart != item.startTimeUnixSeconds {
            return record(StopAuditAttempt(
                item: item, succeeded: true, error: nil,
                signal: SIGTERM, resultCode: 0, escalated: false
            ))
        }

        // Escalate.
        let kill = signaler.send(SIGKILL, to: item.pid)
        if kill.alreadyGone {
            return record(StopAuditAttempt(
                item: item, succeeded: true, error: nil,
                signal: SIGKILL, resultCode: ESRCH, escalated: true
            ))
        }
        if !kill.succeeded {
            return record(StopAuditAttempt(
                item: item, succeeded: false,
                error: errnoDescription(kill.errno, signal: SIGKILL),
                signal: SIGKILL, resultCode: kill.errno, escalated: true
            ))
        }

        await sleep(killGraceNanoseconds)
        let stillAlive = signaler.isAlive(pid: item.pid)
        return record(StopAuditAttempt(
            item: item,
            succeeded: !stillAlive,
            error: stillAlive ? "Process still running after SIGKILL." : nil,
            signal: SIGKILL,
            resultCode: stillAlive ? -1 : 0,
            escalated: true
        ))
    }

    // MARK: - Remove Source

    @MainActor
    public func removeSource(_ item: ProcessItem) async -> ProcessActionOutcome {
        // Gate `.protected_` here even though the routing-eligible source set
        // (launchd with exact/path confidence) rarely intersects with it —
        // an Apple-signed daemon can match exactly. Routing the user to
        // Background Items would only land on a row whose disable button is
        // already refused, so refuse up front with a precise reason.
        guard item.safety != .protected_ else {
            return refuse(item: item, action: .removeSource, refusal: .protectedItem)
        }
        switch router.route(item) {
        case let .routeToBackgroundItems(plistPath, _):
            // No audit entry — the actual disable/delete runs through
            // BackgroundItemActionExecutor and writes its own audit record.
            // Double-logging here would muddy the forensic chain.
            return ProcessActionOutcome(
                processID: item.id,
                action: .removeSource,
                succeeded: true,
                error: nil,
                auditID: nil,
                routedPlistPath: plistPath
            )
        case let .unsupported(refusal, _):
            return refuse(item: item, action: .removeSource, refusal: refusal)
        }
    }

    // MARK: - Refusal logic

    /// Stop refusal rules, applied in order. Layered so the user gets the
    /// most specific reason — `.protected_` first (Trust Layer), then path
    /// (Apple-managed), then PID (kernel/init).
    private func stopRefusal(for item: ProcessItem) -> ProcessActionRefusal? {
        if item.safety == .protected_ { return .protectedItem }
        // PID 0 is the kernel scheduler; PID 1 is launchd. Neither is killable
        // even by root, and asking the user to confirm an impossible action is
        // worse than refusing up front.
        if item.pid <= 1 { return .kernelOrInit }
        if let path = item.executablePath, path.hasPrefix("/System/") {
            return .systemPath
        }
        return nil
    }

    // MARK: - Audit

    /// Bundle of fields a single audit row needs. Inlined struct so the
    /// `record` callsite stays under SwiftLint's parameter-count cap and so
    /// future fields (signal name, attempt count) only touch one signature.
    ///
    /// `resultCode` carries either `0` for success, `-1` when the process
    /// survived `SIGKILL`, or the `errno` returned by `kill(2)` on failure.
    /// It is recorded as `commandExitCode` to match the audit shape Task 3
    /// uses for `launchctl` results, but is not a Unix wait status — `kill(2)`
    /// has no exit code, only an errno.
    private struct StopAuditAttempt {
        let item: ProcessItem
        let succeeded: Bool
        let error: String?
        let signal: Int32
        let resultCode: Int32
        let escalated: Bool
    }

    private func record(_ attempt: StopAuditAttempt) -> ProcessActionOutcome {
        let signalArg = "-\(attempt.signal)"
        var arguments = [signalArg, String(attempt.item.pid)]
        if attempt.escalated {
            // When escalation kicked in, prepend the SIGTERM step so a
            // forensic reader can reconstruct the full attempt without having
            // to correlate two audit lines on PID + timestamp.
            arguments = ["-\(SIGTERM)", String(attempt.item.pid), signalArg, String(attempt.item.pid)]
        }
        let item = attempt.item
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now(),
            tool: "kill",
            command: ProcessAction.stop.verb,
            files: [AuditFile(path: item.executablePath ?? item.command, size: 0)],
            safetyLevel: item.safety,
            confirmationMethod: item.safety.confirmationTier,
            cleanupMethod: .toolNative,
            bytesFreed: 0,
            kind: .command,
            commandToolVersion: nil,
            commandExitCode: attempt.resultCode,
            commandArguments: arguments
        )
        try? audit.write(entry)
        return ProcessActionOutcome(
            processID: item.id,
            action: .stop,
            succeeded: attempt.succeeded,
            error: attempt.error,
            auditID: entry.id,
            routedPlistPath: nil
        )
    }

    private func refuse(
        item: ProcessItem,
        action: ProcessAction,
        refusal: ProcessActionRefusal
    ) -> ProcessActionOutcome {
        ProcessActionOutcome(
            processID: item.id,
            action: action,
            succeeded: false,
            error: refusal.errorDescription,
            auditID: nil,
            routedPlistPath: nil
        )
    }

    private func errnoDescription(_ value: Int32, signal: Int32) -> String {
        let signalName = signal == SIGTERM ? "SIGTERM" : (signal == SIGKILL ? "SIGKILL" : "signal \(signal)")
        guard let cString = strerror(value) else {
            return "\(signalName) failed (errno \(value))."
        }
        let message = String(cString: cString)
        return "\(signalName) failed: \(message) (errno \(value))."
    }
}
