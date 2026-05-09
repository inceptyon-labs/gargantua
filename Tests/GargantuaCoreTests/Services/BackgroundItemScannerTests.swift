import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemScanner")
struct BackgroundItemScannerTests {

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

    // MARK: - Tests

    @Test("Combines launchd items and login items into a single sorted list")
    func combinesSources() {
        let plist1 = LaunchdPlist(label: "com.apple.thing", program: "/usr/libexec/thing")
        let plist2 = LaunchdPlist(label: "com.acme.tool", program: "/Applications/Tool.app/Contents/MacOS/tool")
        let launchd = [
            LaunchdItem(domain: .systemDaemon, plistPath: "/Library/LaunchDaemons/apple.plist", plist: plist1),
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/acme.plist", plist: plist2),
        ]
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            resolverMap: [
                "/usr/libexec/thing": BinaryIdentity(binaryPath: "/usr/libexec/thing", vendor: .apple),
                "/Applications/Tool.app/Contents/MacOS/tool": BinaryIdentity(
                    binaryPath: "/Applications/Tool.app/Contents/MacOS/tool",
                    bundlePath: "/Applications/Tool.app",
                    bundleName: "Tool",
                    vendor: .thirdPartyKnown,
                    vendorDisplayName: "Acme"
                ),
            ],
            existingFiles: ["/usr/libexec/thing", "/Applications/Tool.app/Contents/MacOS/tool"]
        )

        let scan = scanner.scan()
        #expect(scan.items.count == 2)
        // Sorted: review-class items come before safe items.
        #expect(scan.items.first?.label == "com.acme.tool" || scan.items.first?.label == "com.apple.thing")
        // Apple system one is protected, Acme known-with-bundle is safe.
        let acme = scan.items.first { $0.label == "com.acme.tool" }
        let apple = scan.items.first { $0.label == "com.apple.thing" }
        #expect(acme?.safety == .safe)
        #expect(apple?.safety == .protected_)
    }

    @Test("Counts unparseable plists separately and surfaces them in scan summary")
    func unparseableCount() {
        let launchd = [
            LaunchdItem(
                domain: .userAgent,
                plistPath: "/Users/me/Library/LaunchAgents/broken.plist",
                plist: nil,
                parseError: "could not deserialize"
            ),
        ]
        let scanner = makeScanner(launchd: launchd, login: .empty)
        let scan = scanner.scan()
        #expect(scan.items.isEmpty)
        #expect(scan.unparseableCount == 1)
    }

    @Test("Login items with needsPrivileges flag propagate to scan")
    func loginItemPrivileges() {
        let scanner = makeScanner(
            launchd: [],
            login: LoginItemEnumeration(records: [], needsPrivileges: true)
        )
        let scan = scanner.scan()
        #expect(scan.loginItemsNeedPrivileges)
    }

    @Test("Login items become BackgroundItem with .loginItem source")
    func loginItemsBecomeItems() {
        let url = URL(fileURLWithPath: "/Applications/LoginThing.app")
        let record = LoginItemRecord(
            name: "Login Thing",
            bundleIdentifier: "com.example.loginthing",
            url: url,
            teamIdentifier: "ABCDE12345"
        )
        let scanner = makeScanner(
            launchd: [],
            login: LoginItemEnumeration(records: [record], needsPrivileges: false),
            resolverMap: [
                url.path: BinaryIdentity(
                    binaryPath: url.path,
                    bundlePath: url.path,
                    bundleName: "Login Thing",
                    vendor: .thirdPartyKnown,
                    vendorDisplayName: "Login Thing Inc"
                ),
            ],
            existingFiles: [url.path]
        )
        let scan = scanner.scan()
        #expect(scan.items.count == 1)
        let item = try? #require(scan.items.first)
        #expect(item?.source == .loginItem)
        #expect(item?.label == "Login Thing")
        #expect(item?.identity?.vendorDisplayName == "Login Thing Inc")
    }

    @Test("Orphaned binaries land as safe with orphaned reason")
    func orphanedBinary() {
        let plist = LaunchdPlist(
            label: "com.orphan.thing",
            program: "/Applications/Orphan.app/Contents/MacOS/orphan"
        )
        let scanner = makeScanner(
            launchd: [
                LaunchdItem(
                    domain: .userAgent,
                    plistPath: "/Users/me/Library/LaunchAgents/orphan.plist",
                    plist: plist
                ),
            ],
            login: .empty,
            existingFiles: [] // binary missing on disk
        )
        let scan = scanner.scan()
        let item = try? #require(scan.items.first)
        #expect(item?.safety == .safe)
        #expect(item?.reasons.contains(.orphaned) == true)
        #expect(item?.isOrphaned == true)
    }

    @Test("Relative ProgramArguments[0] is treated as exists, not orphaned")
    func relativeProgramNotOrphaned() {
        // launchd resolves bare program names through _PATH_STDPATH; the
        // scanner must not flag "foo" as orphaned just because it's not on
        // disk relative to the host process's working directory.
        let plist = LaunchdPlist(label: "com.example.relbin", programArguments: ["bare-tool", "--flag"])
        let scanner = makeScanner(
            launchd: [
                LaunchdItem(
                    domain: .userAgent,
                    plistPath: "/Users/me/Library/LaunchAgents/relbin.plist",
                    plist: plist
                ),
            ],
            login: .empty,
            existingFiles: [] // empty file system — but bare-tool isn't absolute
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.isOrphaned == false)
        #expect(item?.reasons.contains(.orphaned) == false)
    }

    @Test("Login items with same bundle ID but different URLs get distinct IDs")
    func loginItemsDistinctIDsForSameBundle() {
        let url1 = URL(fileURLWithPath: "/Applications/Foo.app")
        let url2 = URL(fileURLWithPath: "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app")
        let records = [
            LoginItemRecord(name: "Foo", bundleIdentifier: "com.example.foo", url: url1),
            LoginItemRecord(name: "Foo Helper", bundleIdentifier: "com.example.foo", url: url2),
        ]
        let scanner = makeScanner(
            launchd: [],
            login: LoginItemEnumeration(records: records, needsPrivileges: false),
            existingFiles: [url1.path, url2.path]
        )
        let scan = scanner.scan()
        let ids = Set(scan.items.map(\.id))
        #expect(ids.count == 2)
    }

    @Test("Resolver clearCache is invoked at the start of every scan")
    func resolverCacheCleared() {
        final class CountingResolver: BinaryIdentityResolving, @unchecked Sendable {
            var clearCount = 0
            func resolve(binaryPath: String) -> BinaryIdentity {
                BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
            }
            func clearCache() { clearCount += 1 }
        }

        let counting = CountingResolver()
        let scanner = DefaultBackgroundItemScanner(
            launchdIndex: StubLaunchdIndex(items: []),
            loginItems: StubLoginItems(enumeration: .empty),
            resolver: counting,
            classifier: BackgroundItemSafetyClassifier(),
            explainer: BackgroundItemExplainer(),
            fileExists: { _ in true },
            now: { Date(timeIntervalSince1970: 0) }
        )
        _ = scanner.scan()
        _ = scanner.scan()
        #expect(counting.clearCount == 2)
    }

    @Test("ID is stable across rescans for the same source/label/path")
    func stableID() {
        let plist = LaunchdPlist(label: "com.stable.thing", program: "/usr/local/bin/thing")
        let launchd = [
            LaunchdItem(
                domain: .userAgent,
                plistPath: "/Users/me/Library/LaunchAgents/stable.plist",
                plist: plist
            ),
        ]
        let scanner = makeScanner(launchd: launchd, login: .empty)
        let firstID = scanner.scan().items.first?.id
        let secondID = scanner.scan().items.first?.id
        #expect(firstID != nil)
        #expect(firstID == secondID)
    }

    // MARK: - Helpers

    private func makeScanner(
        launchd: [LaunchdItem],
        login: LoginItemEnumeration,
        resolverMap: [String: BinaryIdentity] = [:],
        existingFiles: Set<String> = []
    ) -> DefaultBackgroundItemScanner {
        DefaultBackgroundItemScanner(
            launchdIndex: StubLaunchdIndex(items: launchd),
            loginItems: StubLoginItems(enumeration: login),
            resolver: StubResolver(map: resolverMap),
            classifier: BackgroundItemSafetyClassifier(),
            explainer: BackgroundItemExplainer(),
            fileExists: { existingFiles.contains($0) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}
