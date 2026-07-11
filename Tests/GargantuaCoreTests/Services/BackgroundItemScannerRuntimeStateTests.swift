import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemScanner.RuntimeState")
struct BackgroundItemScannerRuntimeStateTests {

    // MARK: - Stubs

    private struct StubLaunchdIndex: LaunchdItemIndexing {
        let items: [LaunchdItem]
        func enumerate() -> [LaunchdItem] { items }
    }

    private struct StubLoginItems: LoginItemEnumerating {
        let enumeration: LoginItemEnumeration
        func enumerate() -> LoginItemEnumeration { enumeration }
    }

    private struct StubResolver: BinaryIdentityResolving {
        let map: [String: BinaryIdentity]
        func resolve(binaryPath: String) -> BinaryIdentity {
            map[binaryPath] ?? BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
        }
    }

    private struct StubRuntimeProvider: LaunchdRuntimeStateProviding {
        let snapshotToReturn: LaunchdRuntimeSnapshot
        let stateToReturn: LaunchdRuntimeState?
        func snapshot() -> LaunchdRuntimeSnapshot { snapshotToReturn }
        func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? { nil }
        func state(
            label: String,
            source: BackgroundItemSource,
            snapshot: LaunchdRuntimeSnapshot
        ) -> LaunchdRuntimeState? {
            stateToReturn
        }
    }

    /// Counts `snapshot()` calls so tests can assert the scanner batches
    /// exactly one snapshot per pass instead of shelling out per item.
    private final class CountingRuntimeProvider: LaunchdRuntimeStateProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        let snapshotToReturn: LaunchdRuntimeSnapshot
        let stateToReturn: LaunchdRuntimeState?

        init(snapshotToReturn: LaunchdRuntimeSnapshot = .empty, stateToReturn: LaunchdRuntimeState? = nil) {
            self.snapshotToReturn = snapshotToReturn
            self.stateToReturn = stateToReturn
        }

        var snapshotCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        func snapshot() -> LaunchdRuntimeSnapshot {
            lock.lock()
            callCount += 1
            lock.unlock()
            return snapshotToReturn
        }

        func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? { nil }

        func state(
            label: String,
            source: BackgroundItemSource,
            snapshot: LaunchdRuntimeSnapshot
        ) -> LaunchdRuntimeState? {
            stateToReturn
        }
    }

    // MARK: - Tests

    @Test("User agent item's runtime carries pid/lastExitStatus/disabledOverride from the runtime provider")
    func runtimeMergedFromProvider() {
        let plist = LaunchdPlist(label: "com.example.agent", program: "/usr/local/bin/agent")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/agent.plist", plist: plist),
        ]
        let expectedState = LaunchdRuntimeState(isLoaded: true, pid: 4242, lastExitStatus: 0, disabledOverride: false)
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: ["/usr/local/bin/agent"],
            runtimeProvider: StubRuntimeProvider(snapshotToReturn: .empty, stateToReturn: expectedState)
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.runtime == expectedState)
    }

    @Test("snapshot() is called exactly once per scan even with multiple launchd items")
    func snapshotCalledOncePerScan() {
        let plist1 = LaunchdPlist(label: "com.example.one", program: "/usr/local/bin/one")
        let plist2 = LaunchdPlist(label: "com.example.two", program: "/usr/local/bin/two")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/one.plist", plist: plist1),
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/two.plist", plist: plist2),
        ]
        let counting = CountingRuntimeProvider()
        let scanner = makeScanner(launchd: launchd, login: .empty, runtimeProvider: counting)
        let scan = scanner.scan()
        #expect(scan.items.count == 2)
        #expect(counting.snapshotCallCount == 1)
    }

    @Test("Login items always get nil runtime even when the runtime provider would return state")
    func loginItemsRuntimeAlwaysNil() {
        let url = URL(fileURLWithPath: "/Applications/LoginThing.app")
        let record = LoginItemRecord(name: "Login Thing", bundleIdentifier: "com.example.loginthing", url: url)
        let richState = LaunchdRuntimeState(isLoaded: true, pid: 99, lastExitStatus: 0, disabledOverride: false)
        let scanner = makeScanner(
            launchd: [],
            login: LoginItemEnumeration(records: [record], needsPrivileges: false),
            existingFiles: [url.path],
            runtimeProvider: StubRuntimeProvider(snapshotToReturn: .empty, stateToReturn: richState)
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.runtime == nil)
    }

    @Test("Runtime provider returning nil state still produces items, with nil runtime")
    func nilRuntimeStateStillProducesItems() {
        let plist = LaunchdPlist(label: "com.example.noruntime", program: "/usr/local/bin/noruntime")
        let launchd = [
            LaunchdItem(
                domain: .userAgent,
                plistPath: "/Users/me/Library/LaunchAgents/noruntime.plist",
                plist: plist
            ),
        ]
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: ["/usr/local/bin/noruntime"],
            runtimeProvider: StubRuntimeProvider(snapshotToReturn: .empty, stateToReturn: nil)
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item != nil)
        #expect(item?.runtime == nil)
    }

    @Test("Runtime state never affects classification: safety/reasons identical with rich or nil runtime")
    func runtimeDoesNotAffectClassification() {
        let plist = LaunchdPlist(
            label: "com.example.classify",
            program: "/Applications/Classify.app/Contents/MacOS/classify"
        )
        let launchd = [
            LaunchdItem(
                domain: .userAgent,
                plistPath: "/Users/me/Library/LaunchAgents/classify.plist",
                plist: plist
            ),
        ]
        let richState = LaunchdRuntimeState(isLoaded: true, pid: 123, lastExitStatus: 1, disabledOverride: true)
        let existingFiles: Set<String> = ["/Applications/Classify.app/Contents/MacOS/classify"]

        let scanWithRuntime = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: existingFiles,
            runtimeProvider: StubRuntimeProvider(snapshotToReturn: .empty, stateToReturn: richState)
        ).scan()
        let scanWithoutRuntime = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: existingFiles,
            runtimeProvider: StubRuntimeProvider(snapshotToReturn: .empty, stateToReturn: nil)
        ).scan()

        let withRuntime = try? #require(scanWithRuntime.items.first)
        let withoutRuntime = try? #require(scanWithoutRuntime.items.first)
        #expect(withRuntime?.safety == withoutRuntime?.safety)
        #expect(withRuntime?.reasons == withoutRuntime?.reasons)
        #expect(withRuntime?.runtime == richState)
        #expect(withoutRuntime?.runtime == nil)
    }

    // MARK: - Helpers

    private func makeScanner(
        launchd: [LaunchdItem],
        login: LoginItemEnumeration,
        resolverMap: [String: BinaryIdentity] = [:],
        existingFiles: Set<String> = [],
        runtimeProvider: any LaunchdRuntimeStateProviding = StubRuntimeProvider(
            snapshotToReturn: .empty,
            stateToReturn: nil
        )
    ) -> DefaultBackgroundItemScanner {
        DefaultBackgroundItemScanner(
            launchdIndex: StubLaunchdIndex(items: launchd),
            loginItems: StubLoginItems(enumeration: login),
            resolver: StubResolver(map: resolverMap),
            classifier: BackgroundItemSafetyClassifier(),
            explainer: BackgroundItemExplainer(),
            runtimeProvider: runtimeProvider,
            fileExists: { existingFiles.contains($0) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}
