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

    // MARK: - Fixtures

    func makeItem(
        id: String = "userAgent|com.acme.tool|/Users/me/Library/LaunchAgents/com.acme.tool.plist",
        label: String = "com.acme.tool",
        source: BackgroundItemSource = .userLaunchAgent,
        plistPath: String? = "/Users/me/Library/LaunchAgents/com.acme.tool.plist"
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
            isOrphaned: false
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

    @Test("a nil-returning provider is not cached — a later call retries")
    func nilResultIsNotCached() async {
        let item = makeItem()
        let provider = CountingRuntimeProvider(detail: nil)
        let session = BackgroundItemsSession(
            scanner: StubScanner(result: makeScan(items: [item])),
            actionExecutor: nil,
            runtimeProvider: provider
        )
        await session.scan()

        await session.loadRuntimeDetail(for: item)
        await session.loadRuntimeDetail(for: item)

        #expect(provider.printCallCount == 2)
        #expect(session.runtimeDetails[item.id] == nil)
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
