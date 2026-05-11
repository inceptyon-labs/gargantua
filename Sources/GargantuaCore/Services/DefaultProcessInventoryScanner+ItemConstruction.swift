import Foundation

extension DefaultProcessInventoryScanner {
    func makeItem(
        prior: RawProcessSample?,
        current: RawProcessSample,
        launchdItems: [LaunchdItem],
        foregroundPIDs: Set<Int32>,
        resolveUser: (UInt32) -> String?
    ) -> ProcessItem {
        let cpuFraction = computeCPUFraction(prior: prior, current: current)
        let identity = current.executablePath.map(resolver.resolve)
        let (rawSource, confidence) = matcher.match(
            executablePath: current.executablePath,
            command: current.command,
            parentPID: current.parentPID,
            launchdItems: launchdItems
        )

        // Promote .userSession matches to .foregroundApp when the PID is
        // visible to NSWorkspace — the matcher can't see the workspace and
        // would otherwise leave every GUI app misclassified.
        let launchSource: ProcessLaunchSource = {
            if case .userSession = rawSource, foregroundPIDs.contains(current.pid) {
                return .foregroundApp
            }
            return rawSource
        }()

        // "Orphaned launchd source": the matcher tied the running process
        // to a launchd plist, and that plist's executable is gone from disk.
        // Counter-intuitive on its face — if the plist's binary were really
        // missing, the process couldn't be running it — but it fires when
        // launchd has a stale plist that points at a deleted helper while
        // the still-running process holds an open file handle on the
        // deleted inode (typical after an in-place app update or a
        // half-finished uninstall). Restricting to exact/path confidence
        // prevents a label-only heuristic match from falsely flagging an
        // unrelated stale plist as the source of this process.
        let launchSourceOrphaned: Bool = {
            guard confidence == .exact || confidence == .path else { return false }
            if case let .launchd(_, _, plistPath) = launchSource {
                return launchdItemBinaryMissing(plistPath: plistPath, in: launchdItems)
            }
            return false
        }()

        let classifierInput = ProcessClassifierInput(
            command: current.command,
            executablePath: current.executablePath,
            uid: current.uid,
            identity: identity,
            launchSource: launchSource,
            launchConfidence: confidence,
            launchSourceOrphaned: launchSourceOrphaned
        )
        let classification = classifier.classify(classifierInput)

        return ProcessItem(
            id: makeID(
                pid: current.pid,
                executablePath: current.executablePath,
                command: current.command,
                startTimeUnixSeconds: current.startTimeUnixSeconds
            ),
            pid: current.pid,
            parentPID: current.parentPID,
            startTimeUnixSeconds: current.startTimeUnixSeconds,
            command: current.command,
            uid: current.uid,
            owningUser: resolveUser(current.uid) ?? String(current.uid),
            executablePath: current.executablePath,
            cpuFraction: cpuFraction,
            residentBytes: current.residentBytes,
            identity: identity,
            launchSource: launchSource,
            launchConfidence: confidence,
            safety: classification.safety,
            reasons: classification.reasons,
            explanation: classification.explanation
        )
    }

    func computeCPUFraction(prior: RawProcessSample?, current: RawProcessSample) -> Double {
        guard let prior else { return 0 }
        let elapsedNanos = current.sampledAt.timeIntervalSince(prior.sampledAt) * 1_000_000_000
        guard elapsedNanos > 0 else { return 0 }
        // Guard against unsigned wrap when a process has been replaced
        // mid-window or when libproc returns a non-monotonic reading.
        guard current.cpuTimeNanoseconds >= prior.cpuTimeNanoseconds else { return 0 }
        let deltaNanos = Double(current.cpuTimeNanoseconds - prior.cpuTimeNanoseconds)
        return deltaNanos / elapsedNanos
    }

    private func launchdItemBinaryMissing(plistPath: String, in items: [LaunchdItem]) -> Bool {
        guard let item = items.first(where: { $0.plistPath == plistPath }),
              let plist = item.plist,
              let exePath = plist.executablePath else {
            return false
        }
        // launchd resolves bare program names through `_PATH_STDPATH`; only
        // an absolute path that's missing on disk qualifies as orphaned.
        guard exePath.hasPrefix("/") else { return false }
        return !fileExists(exePath)
    }

    private func makeID(
        pid: Int32,
        executablePath: String?,
        command: String,
        startTimeUnixSeconds: UInt64
    ) -> String {
        // Include start time so a recycled PID (and even one with the same
        // binary path) gets a distinct id and SwiftUI doesn't carry over
        // expansion / selection state from the previous instance.
        let key = executablePath ?? command
        return "\(pid)|\(startTimeUnixSeconds)|\(key)"
    }
}
