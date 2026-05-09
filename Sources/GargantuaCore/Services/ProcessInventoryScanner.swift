import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "ProcessInventoryScanner")

/// Result of one process-inventory scan pass.
public struct ProcessInventoryScan: Sendable, Equatable {
    /// Top-N items, sorted by the metric the scanner was asked for.
    public let items: [ProcessItem]
    /// Total number of running processes the snapshot saw — useful so the
    /// footer can say "showing top 50 of 432 running" without the UI having
    /// to re-query.
    public let totalProcessCount: Int
    /// The metric that was used to rank `items`. Carried back so the UI
    /// stays in sync if the user changes the toggle while a scan is in
    /// flight.
    public let sortedBy: ProcessSortMetric
    /// Top-N cap applied to `items`. `nil` means no cap was applied.
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
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
        self.now = now
        self.sleep = sleep
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
            let priorOpt = firstByPID[current.pid]
            // Only treat the prior sample as comparable when the executable
            // path also matches — a recycled PID with a different binary
            // would otherwise inherit the previous process's CPU baseline
            // and report a wildly inflated (or negative) delta.
            let prior: RawProcessSample? = {
                guard let priorOpt else { return nil }
                if priorOpt.executablePath == current.executablePath { return priorOpt }
                return nil
            }()
            let item = makeItem(
                prior: prior,
                current: current,
                launchdItems: launchdItems,
                resolveUser: resolveUser
            )
            items.append(item)
        }

        let sorted = sortAndCap(items, by: metric, topN: topN)
        return ProcessInventoryScan(
            items: sorted,
            totalProcessCount: secondSamples.count,
            sortedBy: metric,
            topN: topN,
            scannedAt: now()
        )
    }

    // MARK: - Item construction

    private func makeItem(
        prior: RawProcessSample?,
        current: RawProcessSample,
        launchdItems: [LaunchdItem],
        resolveUser: (UInt32) -> String?
    ) -> ProcessItem {
        let cpuFraction = computeCPUFraction(prior: prior, current: current)
        let identity = current.executablePath.map(resolver.resolve)
        let (launchSource, confidence) = matcher.match(
            executablePath: current.executablePath,
            command: current.command,
            parentPID: current.parentPID,
            launchdItems: launchdItems
        )

        // An "orphaned launchd source" means: the matcher tied the running
        // process to a launchd plist, but the plist's executable is gone
        // from disk. Counter-intuitive on its face — if the plist's binary
        // were really missing, the process couldn't be running it. In
        // practice this fires when launchd has a stale plist that points at
        // a deleted helper while the still-running process holds an open
        // file handle on the deleted inode (typical after an in-place app
        // update or a half-finished uninstall). It's the cleanup signal:
        // delete the orphaned plist and the process won't respawn.
        let launchSourceOrphaned: Bool = {
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
            id: makeID(pid: current.pid, executablePath: current.executablePath, command: current.command),
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

    private func makeID(pid: Int32, executablePath: String?, command: String) -> String {
        let key = executablePath ?? command
        return "\(pid)|\(key)"
    }

    // MARK: - Sort + cap

    private func sortAndCap(
        _ items: [ProcessItem],
        by metric: ProcessSortMetric,
        topN: Int?
    ) -> [ProcessItem] {
        let sorted = items.sorted(by: { lhs, rhs in
            let lhsPrimary = primary(lhs, metric: metric)
            let rhsPrimary = primary(rhs, metric: metric)
            if lhsPrimary != rhsPrimary { return lhsPrimary > rhsPrimary }
            // Secondary sort: the other metric, so two zero-CPU rows still
            // rank by memory and vice versa.
            let lhsSecondary = secondary(lhs, metric: metric)
            let rhsSecondary = secondary(rhs, metric: metric)
            if lhsSecondary != rhsSecondary { return lhsSecondary > rhsSecondary }
            // Final tie-break by display name then id to keep the order
            // stable across rescans.
            let nameCmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.id < rhs.id
        })
        if let topN, topN > 0 {
            return Array(sorted.prefix(topN))
        }
        return sorted
    }

    private func primary(_ item: ProcessItem, metric: ProcessSortMetric) -> Double {
        switch metric {
        case .cpu: item.cpuFraction
        case .rss: Double(item.residentBytes)
        }
    }

    private func secondary(_ item: ProcessItem, metric: ProcessSortMetric) -> Double {
        switch metric {
        case .cpu: Double(item.residentBytes)
        case .rss: item.cpuFraction
        }
    }
}
