import Foundation
import OSLog

#if canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(subsystem: "com.gargantua.core", category: "ProcessInventoryScanner")

/// Result of one process-inventory scan pass.
public struct ProcessInventoryScan: Sendable, Equatable {
    /// Full ranked list. The view applies `topN` when rendering so that
    /// re-sorting by another metric can pick from the complete population
    /// instead of being trapped inside a previously-capped slice.
    public let items: [ProcessItem]
    /// Total number of running processes the snapshot saw — useful so the
    /// footer can say "showing top 50 of 432 running" without the UI having
    /// to re-query.
    public let totalProcessCount: Int
    /// The metric `items` is currently sorted by. Updated by `resort` calls
    /// in the session so the UI stays in sync.
    public let sortedBy: ProcessSortMetric
    /// Preferred display cap. The scanner does not enforce this — the view
    /// applies `.prefix(topN)` so toggling the sort metric never strands
    /// items outside the previously-capped slice.
    public let topN: Int?
    /// When the scan completed.
    public let scannedAt: Date

    public init(
        items: [ProcessItem],
        totalProcessCount: Int,
        sortedBy: ProcessSortMetric,
        topN: Int?,
        scannedAt: Date
    ) {
        self.items = items
        self.totalProcessCount = totalProcessCount
        self.sortedBy = sortedBy
        self.topN = topN
        self.scannedAt = scannedAt
    }

    public static let empty = ProcessInventoryScan(
        items: [],
        totalProcessCount: 0,
        sortedBy: .cpu,
        topN: nil,
        scannedAt: .distantPast
    )
}

/// Orchestrates `ProcessSnapshotProvider` + `LaunchdItemIndex` +
/// `BinaryIdentityResolver` + `ProcessLaunchSourceMatcher` +
/// `ProcessSafetyClassifier` into a single `[ProcessItem]` list.
public protocol ProcessInventoryScanning: Sendable {
    /// Run a scan, ranking by `metric` and capping at `topN` items.
    func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan
}

public struct DefaultProcessInventoryScanner: ProcessInventoryScanning {
    /// Wall-clock interval between the two snapshots used to derive CPU
    /// deltas. 500 ms is short enough that the scan feels instant and long
    /// enough that very-quiet processes still show non-zero CPU when they
    /// blip during the window.
    public static let defaultSampleIntervalNanoseconds: UInt64 = 500_000_000

    private let snapshotProvider: any ProcessSnapshotProviding
    private let launchdIndex: any LaunchdItemIndexing
    private let resolver: any BinaryIdentityResolving
    private let matcher: ProcessLaunchSourceMatcher
    private let classifier: ProcessSafetyClassifier
    private let fileExists: @Sendable (String) -> Bool
    private let userNameForUID: @Sendable (UInt32) -> String?
    private let foregroundPIDs: @Sendable () -> Set<Int32>
    private let sampleIntervalNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async -> Void

    public init(
        snapshotProvider: any ProcessSnapshotProviding = DefaultProcessSnapshotProvider(),
        launchdIndex: any LaunchdItemIndexing = DefaultLaunchdItemIndex(),
        resolver: any BinaryIdentityResolving = DefaultBinaryIdentityResolver(),
        matcher: ProcessLaunchSourceMatcher = ProcessLaunchSourceMatcher(),
        classifier: ProcessSafetyClassifier = ProcessSafetyClassifier(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        userNameForUID: @escaping @Sendable (UInt32) -> String? = DefaultProcessSnapshotProvider.lookupUserName,
        foregroundPIDs: @escaping @Sendable () -> Set<Int32> = DefaultProcessInventoryScanner.detectForegroundPIDs,
        sampleIntervalNanoseconds: UInt64 = DefaultProcessInventoryScanner.defaultSampleIntervalNanoseconds,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.snapshotProvider = snapshotProvider
        self.launchdIndex = launchdIndex
        self.resolver = resolver
        self.matcher = matcher
        self.classifier = classifier
        self.fileExists = fileExists
        self.userNameForUID = userNameForUID
        self.foregroundPIDs = foregroundPIDs
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
        self.now = now
        self.sleep = sleep
    }

    /// Default foreground-PID detector. Bridges `NSWorkspace.runningApplications`
    /// to a `Set<Int32>` so the scanner can promote GUI apps from `userSession`
    /// to `foregroundApp`. Empty on non-AppKit platforms / sandboxed runs that
    /// can't see the workspace.
    @Sendable
    public static func detectForegroundPIDs() -> Set<Int32> {
        #if canImport(AppKit)
            var pids: Set<Int32> = []
            for app in NSWorkspace.shared.runningApplications {
                pids.insert(app.processIdentifier)
            }
            return pids
        #else
            return []
        #endif
    }

    public func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan {
        // Long-lived resolvers cache per binary path; without an explicit
        // clear, a replaced binary at the same path could keep its prior
        // trusted identity across rescans.
        resolver.clearCache()

        let firstSamples = snapshotProvider.snapshot()
        await sleep(sampleIntervalNanoseconds)
        let secondSamples = snapshotProvider.snapshot()

        let launchdItems = launchdIndex.enumerate()
        let foregroundSet = foregroundPIDs()

        // Build a quick lookup from PID → first sample so we can compute the
        // CPU delta without an O(n²) scan.
        var firstByPID: [Int32: RawProcessSample] = [:]
        firstByPID.reserveCapacity(firstSamples.count)
        for sample in firstSamples { firstByPID[sample.pid] = sample }

        // Within a single scan, most processes share the same UID (the
        // logged-in user), so caching the lookup avoids ~95% of redundant
        // `getpwuid_r` calls per scan.
        var userNameCache: [UInt32: String?] = [:]
        let resolveUser: (UInt32) -> String? = { uid in
            if let cached = userNameCache[uid] { return cached }
            let name = userNameForUID(uid)
            userNameCache[uid] = name
            return name
        }

        var items: [ProcessItem] = []
        items.reserveCapacity(secondSamples.count)
        for current in secondSamples {
            let prior = comparablePrior(for: current, in: firstByPID)
            let item = makeItem(
                prior: prior,
                current: current,
                launchdItems: launchdItems,
                foregroundPIDs: foregroundSet,
                resolveUser: resolveUser
            )
            items.append(item)
        }

        let sorted = rank(items, by: metric)
        return ProcessInventoryScan(
            items: sorted,
            totalProcessCount: secondSamples.count,
            sortedBy: metric,
            topN: topN,
            scannedAt: now()
        )
    }

    /// Returns the prior sample only when it represents the SAME process
    /// instance as `current`. Two checks gate this:
    ///   1. Executable path matches (cheap recycled-PID guard).
    ///   2. Process start time matches — handles the case where the same
    ///      binary was respawned within the sample window (e.g. a daemon
    ///      managed by `KeepAlive`); without this, the new instance would
    ///      inherit a CPU baseline that predates its birth.
    private func comparablePrior(
        for current: RawProcessSample,
        in firstByPID: [Int32: RawProcessSample]
    ) -> RawProcessSample? {
        guard let prior = firstByPID[current.pid] else { return nil }
        if prior.executablePath != current.executablePath { return nil }
        if prior.startTimeUnixSeconds != current.startTimeUnixSeconds { return nil }
        return prior
    }

    // MARK: - Item construction

    private func makeItem(
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

    private func computeCPUFraction(prior: RawProcessSample?, current: RawProcessSample) -> Double {
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

    // MARK: - Ranking

    /// Single-source-of-truth ordering used by both the scanner and the
    /// session's in-place `resort`. Mirrored in `ProcessInventorySession.rank`
    /// — keep them in sync if the comparators change.
    private func rank(_ items: [ProcessItem], by metric: ProcessSortMetric) -> [ProcessItem] {
        items.sorted(by: { lhs, rhs in
            let lhsPrimary = Self.primary(lhs, metric: metric)
            let rhsPrimary = Self.primary(rhs, metric: metric)
            if lhsPrimary != rhsPrimary { return lhsPrimary > rhsPrimary }
            let lhsSecondary = Self.secondary(lhs, metric: metric)
            let rhsSecondary = Self.secondary(rhs, metric: metric)
            if lhsSecondary != rhsSecondary { return lhsSecondary > rhsSecondary }
            let nameCmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.id < rhs.id
        })
    }

    static func primary(_ item: ProcessItem, metric: ProcessSortMetric) -> Double {
        switch metric {
        case .cpu: item.cpuFraction
        case .rss: Double(item.residentBytes)
        }
    }

    static func secondary(_ item: ProcessItem, metric: ProcessSortMetric) -> Double {
        switch metric {
        case .cpu: Double(item.residentBytes)
        case .rss: item.cpuFraction
        }
    }
}
