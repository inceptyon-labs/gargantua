import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemsSession runtime detail")
@MainActor
struct BackgroundItemsSessionTests {

    // MARK: - Stubs

    final class StubScanner: BackgroundItemScanning, @unchecked Sendable {
        private let result: BackgroundItemScan

        init(result: BackgroundItemScan) {
            self.result = result
        }

        func scan() -> BackgroundItemScan { result }
    }

    /// Counting stub for `LaunchdRuntimeStateProviding.printDetail`. Records
    /// every call so tests can assert on-expand fetch/cache/dedupe behavior
    /// without shelling out to real `launchctl`.
    final class CountingRuntimeProvider: LaunchdRuntimeStateProviding, @unchecked Sendable {
        nonisolated(unsafe) private var _printCalls: [String] = []
        nonisolated(unsafe) private var _detail: LaunchdRuntimeDetail?
        private let lock = NSLock()

        init(detail: LaunchdRuntimeDetail?) {
            self._detail = detail
        }

        var printCallCount: Int { lock.withLock { _printCalls.count } }

        func snapshot() -> LaunchdRuntimeSnapshot { .empty }

        func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? {
            lock.withLock {
                _printCalls.append(label)
                return _detail
            }
        }

        func state(
            label: String,
            source: BackgroundItemSource,
            snapshot: LaunchdRuntimeSnapshot
        ) -> LaunchdRuntimeState? {
            nil
        }
    }

    /// Provider whose `printDetail` blocks until the test releases it, so a
    /// test can invalidate the cache while a fetch is suspended mid-flight.
    /// Each call gets its own release gate (indexed by call order) so tests
    /// can resume overlapping fetches deterministically.
    final class GatedRuntimeProvider: LaunchdRuntimeStateProviding, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let releases: [DispatchSemaphore]
        nonisolated(unsafe) private var _printCallCount = 0
        private let lock = NSLock()
        private let detail: LaunchdRuntimeDetail

        init(detail: LaunchdRuntimeDetail, expectedCalls: Int = 2) {
            self.detail = detail
            self.releases = (0 ..< max(1, expectedCalls)).map { _ in DispatchSemaphore(value: 0) }
        }

        var printCallCount: Int { lock.withLock { _printCallCount } }

        func snapshot() -> LaunchdRuntimeSnapshot { .empty }

        func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? {
            let callIndex = lock.withLock {
                _printCallCount += 1
                return _printCallCount - 1
            }
            started.signal()
            releases[min(callIndex, releases.count - 1)].wait()
            return detail
        }

        func state(
            label: String,
            source: BackgroundItemSource,
            snapshot: LaunchdRuntimeSnapshot
        ) -> LaunchdRuntimeState? {
            nil
        }
    }

    // MARK: - Fixtures

    func makeItem(
        id: String = "userAgent|com.acme.tool|/Users/me/Library/LaunchAgents/com.acme.tool.plist",
        label: String = "com.acme.tool",
        source: BackgroundItemSource = .userLaunchAgent,
        plistPath: String? = "/Users/me/Library/LaunchAgents/com.acme.tool.plist",
        runtime: LaunchdRuntimeState? = nil
    ) -> BackgroundItem {
        BackgroundItem(
            id: id,
            label: label,
            source: source,
            plistPath: plistPath,
            executablePath: "/usr/local/bin/\(label)",
            identity: nil,
            safety: .review,
            reasons: [],
            explanation: "Test item",
            isOrphaned: false,
            runtime: runtime
        )
    }

    func makeScan(items: [BackgroundItem]) -> BackgroundItemScan {
        BackgroundItemScan(
            items: items,
            loginItemsNeedPrivileges: false,
            unparseableCount: 0,
            scannedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )
    }

    // MARK: - Tests

    @Test("loadRuntimeDetail caches — two sequential awaits call the provider once")
    func loadRuntimeDetailCaches() async {
        let item = makeItem()
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        let provider = CountingRuntimeProvider(detail: detail)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()

        await session.loadRuntimeDetail(for: item)
        await session.loadRuntimeDetail(for: item)

        #expect(provider.printCallCount == 1)
        #expect(session.runtimeDetails[item.id]?.pid == 5036)
    }

    @Test("a nil result is remembered as attempted — no re-fetch until the next scan generation")
    func nilResultDoesNotRetryWithinGeneration() async {
        let item = makeItem()
        let provider = CountingRuntimeProvider(detail: nil)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()

        // `.onAppear` re-fires on every collapse/re-expand; a persistently
        // failing print must not shell out again within the same generation.
        await session.loadRuntimeDetail(for: item)
        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 1)
        #expect(session.runtimeDetails[item.id] == nil)

        // A fresh scan opens a new generation and may retry.
        await session.scan()
        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 2)
    }

    @Test("clearScan empties the cache so the next load re-fetches")
    func clearScanInvalidatesCache() async {
        let item = makeItem()
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        let provider = CountingRuntimeProvider(detail: detail)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()
        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 1)

        session.clearScan()
        #expect(session.runtimeDetails.isEmpty)

        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 2)
    }

    @Test("a rescan empties the cache so the next load re-fetches")
    func rescanInvalidatesCache() async {
        let item = makeItem()
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        let provider = CountingRuntimeProvider(detail: detail)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()
        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 1)

        await session.scan()
        #expect(session.runtimeDetails.isEmpty)

        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 2)
    }

    @Test("a fetch suspended across an invalidation does not write stale detail into the fresh cache")
    func staleFetchDoesNotRepopulateInvalidatedCache() async {
        let item = makeItem()
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        let provider = GatedRuntimeProvider(detail: detail)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()

        // Suspend a fetch inside printDetail, invalidate underneath it, then
        // let it resume — its result describes the previous generation and
        // must be dropped.
        let load = Task { await session.loadRuntimeDetail(for: item) }
        await awaitSignal(provider.started)
        session.clearScan()
        provider.releases[0].signal()
        await load.value

        #expect(session.runtimeDetails[item.id] == nil)

        // The fresh generation re-fetches and caches normally.
        provider.releases[1].signal()
        await session.loadRuntimeDetail(for: item)
        #expect(provider.printCallCount == 2)
        #expect(session.runtimeDetails[item.id]?.pid == 5036)
    }

    @Test("a stale fetch's cleanup does not erase the next generation's in-flight marker")
    func staleFetchCleanupLeavesNewGenerationMarker() async {
        let item = makeItem()
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        let provider = GatedRuntimeProvider(detail: detail, expectedCalls: 2)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()

        // Fetch A (old generation) suspends; invalidate; fetch B (new
        // generation) starts for the same id and suspends too.
        let loadA = Task { await session.loadRuntimeDetail(for: item) }
        await awaitSignal(provider.started)
        session.clearScan()
        let loadB = Task { await session.loadRuntimeDetail(for: item) }
        await awaitSignal(provider.started)

        // A resumes stale: it must neither write back nor remove B's marker.
        provider.releases[0].signal()
        await loadA.value
        #expect(session.loadingDetailIDs.contains(item.id))
        #expect(session.runtimeDetails[item.id] == nil)

        // B resumes current and lands its detail normally.
        provider.releases[1].signal()
        await loadB.value
        #expect(!session.loadingDetailIDs.contains(item.id))
        #expect(session.runtimeDetails[item.id]?.pid == 5036)
        #expect(provider.printCallCount == 2)
    }

    @Test("perform(.delete) synthesizes the disabled reason for an override-disabled item")
    func performDeleteSynthesizesDisabledFromOverride() async {
        final class RecordingExecutor: BackgroundItemActionExecuting, @unchecked Sendable {
            nonisolated(unsafe) var deletedItem: BackgroundItem?
            @MainActor func disable(_ item: BackgroundItem) async -> BackgroundItemActionOutcome {
                BackgroundItemActionOutcome(itemID: item.id, action: .disable, succeeded: true, error: nil)
            }
            @MainActor func enable(_ item: BackgroundItem) async -> BackgroundItemActionOutcome {
                BackgroundItemActionOutcome(itemID: item.id, action: .enable, succeeded: true, error: nil)
            }
            @MainActor func delete(
                _ item: BackgroundItem,
                confirmedAt confirmation: ConfirmationTier
            ) async -> BackgroundItemActionOutcome {
                deletedItem = item
                return BackgroundItemActionOutcome(itemID: item.id, action: .delete, succeeded: true, error: nil)
            }
        }

        let runtime = LaunchdRuntimeState(isLoaded: false, pid: nil, lastExitStatus: nil, disabledOverride: true)
        let item = makeItem(runtime: runtime)
        let executor = RecordingExecutor()
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: executor,
            runtimeProvider: CountingRuntimeProvider(detail: nil)
        )

        let outcome = await session.perform(.delete, on: item)

        #expect(outcome.succeeded)
        #expect(executor.deletedItem?.reasons.contains(.disabledFlag) == true)
    }

    @Test("an item without a plist path (login item) never calls the provider")
    func loginItemSkipsProvider() async {
        let item = makeItem(
            id: "loginItem|com.acme.tool|",
            source: .loginItem,
            plistPath: nil
        )
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        let provider = CountingRuntimeProvider(detail: detail)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()

        await session.loadRuntimeDetail(for: item)

        #expect(provider.printCallCount == 0)
        #expect(session.runtimeDetails[item.id] == nil)
    }
}
