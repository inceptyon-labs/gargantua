import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessInventoryScanner")
// swiftlint:disable:next type_body_length
struct ProcessInventoryScannerTests {

    // MARK: - Stubs

    /// Two-shot snapshot stub: returns `first` on the initial `snapshot()`
    /// call, then `second` on every subsequent call. The scanner takes
    /// exactly two snapshots per scan; this matches that contract.
    private final class TwoShotProvider: ProcessSnapshotProviding, @unchecked Sendable {
        let first: [RawProcessSample]
        let second: [RawProcessSample]
        var calls = 0
        init(first: [RawProcessSample], second: [RawProcessSample]) {
            self.first = first
            self.second = second
        }
        func snapshot() -> [RawProcessSample] {
            calls += 1
            return calls == 1 ? first : second
        }
    }

    private struct StubLaunchdIndex: LaunchdItemIndexing {
        let items: [LaunchdItem]
        func enumerate() -> [LaunchdItem] { items }
    }

    private struct StubResolver: BinaryIdentityResolving {
        let map: [String: BinaryIdentity]
        func resolve(binaryPath: String) -> BinaryIdentity {
            map[binaryPath] ?? BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
        }
    }

    // MARK: - Helpers

    private func sample(
        pid: Int32,
        parent: Int32 = 1,
        uid: UInt32 = 501,
        command: String,
        path: String?,
        cpuTime: UInt64,
        rss: UInt64 = 0,
        startTime: UInt64 = 1_699_000_000,
        at offsetSeconds: TimeInterval = 0
    ) -> RawProcessSample {
        RawProcessSample(
            pid: pid,
            parentPID: parent,
            uid: uid,
            command: command,
            executablePath: path,
            startTimeUnixSeconds: startTime,
            cpuTimeNanoseconds: cpuTime,
            residentBytes: rss,
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds)
        )
    }

    private func makeScanner(
        first: [RawProcessSample],
        second: [RawProcessSample],
        launchd: [LaunchdItem] = [],
        resolverMap: [String: BinaryIdentity] = [:],
        existingFiles: Set<String> = [],
        foregroundPIDs: Set<Int32> = []
    ) -> DefaultProcessInventoryScanner {
        DefaultProcessInventoryScanner(
            snapshotProvider: TwoShotProvider(first: first, second: second),
            launchdIndex: StubLaunchdIndex(items: launchd),
            resolver: StubResolver(map: resolverMap),
            matcher: ProcessLaunchSourceMatcher(),
            classifier: ProcessSafetyClassifier(),
            fileExists: { existingFiles.contains($0) },
            userNameForUID: { uid in uid == 501 ? "alice" : nil },
            foregroundPIDs: { foregroundPIDs },
            sampleIntervalNanoseconds: 0,
            now: { Date(timeIntervalSince1970: 1_700_000_001) },
            sleep: { _ in }
        )
    }

    // MARK: - Tests

    @Test("CPU delta is computed across the two snapshots")
    func cpuDelta() async {
        // Process used 0.5s of CPU over a 1s wall-clock window → 50% of one core.
        let first = sample(pid: 100, command: "worker", path: "/usr/local/bin/worker", cpuTime: 0, at: 0)
        let second = sample(pid: 100, command: "worker", path: "/usr/local/bin/worker", cpuTime: 500_000_000, at: 1)
        let scanner = makeScanner(first: [first], second: [second])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try? #require(scan.items.first)
        #expect(abs((item?.cpuFraction ?? 0) - 0.5) < 0.001)
    }

    @Test("CPU is zero when the prior sample is missing (newly-spawned process)")
    func cpuZeroWithoutPrior() async {
        let second = sample(pid: 200, command: "fresh", path: "/usr/bin/fresh", cpuTime: 1_000_000_000, at: 1)
        let scanner = makeScanner(first: [], second: [second])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first?.cpuFraction == 0)
    }

    @Test("Recycled PID with different exec path drops the prior baseline")
    func recycledPIDDoesNotInheritCPU() async {
        // Prior sample at pid 300 was a different binary; second snapshot's
        // CPU time would be artificially huge if we naively diffed. Verify we
        // detect the path mismatch and report 0% rather than a wild number.
        let first = sample(pid: 300, command: "old", path: "/old/path", cpuTime: 100, at: 0)
        let second = sample(pid: 300, command: "new", path: "/new/path", cpuTime: 1_000_000_000, at: 1)
        let scanner = makeScanner(first: [first], second: [second])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try? #require(scan.items.first)
        #expect(item?.cpuFraction == 0)
        #expect(item?.executablePath == "/new/path")
    }

    @Test("Sort by CPU descending puts highest CPU first")
    func sortByCPU() async {
        let firstA = sample(pid: 1, command: "a", path: "/a", cpuTime: 0, at: 0)
        let secondA = sample(pid: 1, command: "a", path: "/a", cpuTime: 100_000_000, at: 1) // 10%
        let firstB = sample(pid: 2, command: "b", path: "/b", cpuTime: 0, at: 0)
        let secondB = sample(pid: 2, command: "b", path: "/b", cpuTime: 800_000_000, at: 1) // 80%
        let scanner = makeScanner(first: [firstA, firstB], second: [secondA, secondB])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.map(\.command) == ["b", "a"])
    }

    @Test("Sort by RSS descending puts highest memory first")
    func sortByRSS() async {
        let s1 = sample(pid: 1, command: "small", path: "/s", cpuTime: 0, rss: 1_000_000, at: 1)
        let s2 = sample(pid: 2, command: "large", path: "/l", cpuTime: 0, rss: 100_000_000, at: 1)
        let scanner = makeScanner(first: [], second: [s1, s2])

        let scan = await scanner.scan(metric: .rss, topN: nil)
        #expect(scan.items.map(\.command) == ["large", "small"])
    }

    @Test("topN is metadata; scanner returns the full ranked population")
    func topNIsMetadata() async {
        // The scanner now returns all items so the view can re-rank by
        // another metric without losing items outside the original top-N
        // slice. The view applies `.prefix(topN)` at render time.
        let samples = (1 ... 100).map { i in
            sample(pid: Int32(i), command: "p\(i)", path: "/p\(i)", cpuTime: UInt64(i) * 1_000_000, at: 1)
        }
        let scanner = makeScanner(first: [], second: samples)
        let scan = await scanner.scan(metric: .cpu, topN: 10)
        #expect(scan.items.count == 100)
        #expect(scan.totalProcessCount == 100)
        #expect(scan.topN == 10)
    }

    @Test("Resolver clearCache invoked at the start of every scan")
    func resolverCacheCleared() async {
        final class CountingResolver: BinaryIdentityResolving, @unchecked Sendable {
            var clearCount = 0
            func resolve(binaryPath: String) -> BinaryIdentity {
                BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
            }
            func clearCache() { clearCount += 1 }
        }
        let counting = CountingResolver()
        let scanner = DefaultProcessInventoryScanner(
            snapshotProvider: TwoShotProvider(first: [], second: []),
            launchdIndex: StubLaunchdIndex(items: []),
            resolver: counting,
            matcher: ProcessLaunchSourceMatcher(),
            classifier: ProcessSafetyClassifier(),
            fileExists: { _ in true },
            userNameForUID: { _ in nil },
            foregroundPIDs: { [] },
            sampleIntervalNanoseconds: 0,
            now: { Date() },
            sleep: { _ in }
        )

        _ = await scanner.scan(metric: .cpu, topN: nil)
        _ = await scanner.scan(metric: .cpu, topN: nil)
        #expect(counting.clearCount == 2)
    }

    @Test("Launchd-matched process surfaces its plist path through launchSource")
    func launchSourcePropagated() async {
        let plist = LaunchdPlist(label: "com.acme.helper", program: "/Applications/Acme.app/Contents/MacOS/helper")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/acme.plist", plist: plist)
        let s = sample(pid: 42, parent: 1, command: "helper", path: "/Applications/Acme.app/Contents/MacOS/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [s],
            launchd: [item],
            existingFiles: ["/Applications/Acme.app/Contents/MacOS/helper"]
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let process = try? #require(scan.items.first)
        #expect(process?.launchConfidence == .exact)
        #expect(process?.launchSource.plistPath == "/Users/me/Library/LaunchAgents/acme.plist")
    }

    @Test("Orphaned launchd source is detected when plist's binary is missing")
    func orphanedDetection() async {
        let plist = LaunchdPlist(label: "com.zombie.helper", program: "/Applications/Gone.app/Contents/MacOS/helper")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: plist)
        let s = sample(pid: 77, command: "helper", path: "/Applications/Gone.app/Contents/MacOS/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [s],
            launchd: [item],
            existingFiles: [] // plist's binary missing
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let process = try? #require(scan.items.first)
        #expect(process?.safety == .safe)
        #expect(process?.reasons.contains(.orphaned) == true)
    }

    @Test("ID is stable across rescans for the same pid + binary")
    func stableIDAcrossScans() async {
        let s = sample(pid: 99, command: "stable", path: "/usr/bin/stable", cpuTime: 0, at: 1)
        let scanner = makeScanner(first: [], second: [s])

        let firstID = (await scanner.scan(metric: .cpu, topN: nil)).items.first?.id
        let secondID = (await scanner.scan(metric: .cpu, topN: nil)).items.first?.id
        #expect(firstID != nil)
        #expect(firstID == secondID)
    }

    @Test("Owning user resolves via the injected lookup, falling back to UID")
    func userLookup() async {
        let resolved = sample(pid: 1, uid: 501, command: "alice-proc", path: "/p", cpuTime: 0, at: 1)
        let unresolved = sample(pid: 2, uid: 6502, command: "unknown-proc", path: "/q", cpuTime: 0, at: 1)
        let scanner = makeScanner(first: [], second: [resolved, unresolved])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first(where: { $0.command == "alice-proc" })?.owningUser == "alice")
        #expect(scan.items.first(where: { $0.command == "unknown-proc" })?.owningUser == "6502")
    }

    @Test("Total process count reflects the live snapshot, with topN as metadata")
    func totalCountAndTopNMetadata() async {
        let samples = (1 ... 5).map { i in
            sample(pid: Int32(i), command: "p\(i)", path: "/p\(i)", cpuTime: 0, rss: UInt64(i) * 1_000_000, at: 1)
        }
        let scanner = makeScanner(first: [], second: samples)
        let scan = await scanner.scan(metric: .rss, topN: 2)
        #expect(scan.totalProcessCount == 5)
        #expect(scan.items.count == 5)
        #expect(scan.topN == 2)
    }

    @Test("Recycled PID with same exec path but different start time drops baseline")
    func recycledPIDSameBinaryDifferentStartTime() async {
        // Same PID, same exec path, but startTime moved → it's a respawned
        // process; the new instance must not inherit the old CPU baseline.
        let prior = sample(pid: 400, command: "helper", path: "/h", cpuTime: 100, startTime: 1_699_000_000, at: 0)
        let current = sample(pid: 400, command: "helper", path: "/h", cpuTime: 1_000_000_000, startTime: 1_699_000_500, at: 1)
        let scanner = makeScanner(first: [prior], second: [current])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first?.cpuFraction == 0)
    }

    @Test("Heuristic launchd match does NOT trigger orphaned reason")
    func heuristicMatchSuppressesOrphan() async {
        // Process command shares a name with an unrelated stale plist whose
        // executable is missing. Without the confidence guard the scanner
        // would falsely tag this as orphaned/safe.
        let stalePlist = LaunchdPlist(label: "com.unrelated.helper", program: "/Applications/Gone.app/Contents/MacOS/helper")
        let stale = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: stalePlist)
        let current = sample(pid: 50, parent: 1, command: "helper", path: "/usr/local/bin/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [current],
            launchd: [stale],
            existingFiles: ["/usr/local/bin/helper"] // process's own binary exists, plist's doesn't
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try? #require(scan.items.first)
        // Heuristic match is fine, but the orphan signal must not fire.
        #expect(item?.launchConfidence == .heuristic)
        #expect(item?.reasons.contains(.orphaned) == false)
        #expect(item?.safety != .safe)
    }

    @Test("Heuristic launchd match with known vendor stays at review (not safe)")
    func heuristicKnownVendorStaysReview() async {
        // Known vendor + label-only heuristic match should NOT promote to
        // safe; only exact/path matches earn that.
        let stalePlist = LaunchdPlist(label: "com.acme.tool")
        let stale = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: stalePlist)
        let identity = BinaryIdentity(
            binaryPath: "/usr/local/bin/tool",
            bundlePath: "/Applications/Acme.app",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Acme"
        )
        let current = sample(pid: 60, parent: 1, command: "tool", path: "/usr/local/bin/tool", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [current],
            launchd: [stale],
            resolverMap: ["/usr/local/bin/tool": identity],
            existingFiles: ["/usr/local/bin/tool"]
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try? #require(scan.items.first)
        #expect(item?.launchConfidence == .heuristic)
        #expect(item?.safety == .review)
    }

    @Test("Foreground PIDs are promoted from userSession to foregroundApp")
    func foregroundPromotion() async {
        let current = sample(pid: 999, parent: 1, command: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [current],
            foregroundPIDs: [999]
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try? #require(scan.items.first)
        #expect(item?.launchSource == .foregroundApp)
        #expect(item?.reasons.contains(.foregroundApp) == true)
    }

    @Test("Item ID includes start time so respawned same-binary PIDs are distinct")
    func idIncludesStartTime() async {
        let s1 = sample(pid: 77, command: "x", path: "/x", cpuTime: 0, startTime: 1_000, at: 1)
        let s2 = sample(pid: 77, command: "x", path: "/x", cpuTime: 0, startTime: 2_000, at: 1)

        let scannerA = makeScanner(first: [], second: [s1])
        let scannerB = makeScanner(first: [], second: [s2])

        let idA = (await scannerA.scan(metric: .cpu, topN: nil)).items.first?.id
        let idB = (await scannerB.scan(metric: .cpu, topN: nil)).items.first?.id
        #expect(idA != nil)
        #expect(idB != nil)
        #expect(idA != idB)
    }
}
