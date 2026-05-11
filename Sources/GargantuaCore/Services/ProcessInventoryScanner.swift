import Foundation
import OSLog

#if canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(subsystem: "com.gargantua.core", category: "ProcessInventoryScanner")

public struct DefaultProcessInventoryScanner: ProcessInventoryScanning {
    /// Wall-clock interval between the two snapshots used to derive CPU
    /// deltas. 500 ms is short enough that the scan feels instant and long
    /// enough that very-quiet processes still show non-zero CPU when they
    /// blip during the window.
    public static let defaultSampleIntervalNanoseconds: UInt64 = 500_000_000

    let snapshotProvider: any ProcessSnapshotProviding
    let launchdIndex: any LaunchdItemIndexing
    let resolver: any BinaryIdentityResolving
    let matcher: ProcessLaunchSourceMatcher
    let classifier: ProcessSafetyClassifier
    let fileExists: @Sendable (String) -> Bool
    let userNameForUID: @Sendable (UInt32) -> String?
    let foregroundPIDs: @Sendable () -> Set<Int32>
    let sampleIntervalNanoseconds: UInt64
    let now: @Sendable () -> Date
    let sleep: @Sendable (UInt64) async -> Void

    public init(
        snapshotProvider: any ProcessSnapshotProviding = DefaultProcessSnapshotProvider(),
        launchdIndex: any LaunchdItemIndexing = DefaultLaunchdItemIndex(),
        resolver: any BinaryIdentityResolving = DefaultBinaryIdentityResolver(
            signatureVerifier: DefaultCodeSignatureVerifier(includeNotarization: false)
        ),
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

        let rankedSamples = rankSamples(
            secondSamples,
            firstByPID: firstByPID,
            metric: metric,
            topN: topN
        )

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
        items.reserveCapacity(rankedSamples.count)
        for current in rankedSamples {
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
    func comparablePrior(
        for current: RawProcessSample,
        in firstByPID: [Int32: RawProcessSample]
    ) -> RawProcessSample? {
        guard let prior = firstByPID[current.pid] else { return nil }
        if prior.executablePath != current.executablePath { return nil }
        if prior.startTimeUnixSeconds != current.startTimeUnixSeconds { return nil }
        return prior
    }
}
