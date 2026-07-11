import Foundation
import Testing
@testable import GargantuaCore

// Owning-app evidence wiring (parentAppInstalled / knownVendorAppMissing)
// computed by the scanner itself, memoized per scan pass. Split from
// BackgroundItemScannerTests to keep that suite's type body under the
// 300-line SwiftLint limit.
@Suite("BackgroundItemScanner — owning app evidence")
struct BackgroundItemScannerOwningAppTests {

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

    private struct NilStateRuntimeProvider: LaunchdRuntimeStateProviding {
        func snapshot() -> LaunchdRuntimeSnapshot { .empty }
        func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? { nil }
        func state(
            label: String,
            source: BackgroundItemSource,
            snapshot: LaunchdRuntimeSnapshot
        ) -> LaunchdRuntimeState? { nil }
    }

    /// Counts `isInstalled`/`isAnyAppInstalled` calls so tests can assert the
    /// scanner memoizes owning-app lookups instead of re-querying per item.
    private final class CountingOwningAppResolver: OwningAppResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var installedQueries: [String] = []
        private var prefixQueries: [String] = []
        private let installedResult: Bool
        private let prefixResult: Bool

        init(installedResult: Bool = false, prefixResult: Bool = false) {
            self.installedResult = installedResult
            self.prefixResult = prefixResult
        }

        func isInstalled(bundleID: String) -> Bool {
            lock.lock()
            installedQueries.append(bundleID)
            lock.unlock()
            return installedResult
        }

        func isAnyAppInstalled(bundleIDPrefix: String) -> Bool {
            lock.lock()
            prefixQueries.append(bundleIDPrefix)
            lock.unlock()
            return prefixResult
        }

        var installedCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return installedQueries.count
        }

        var prefixCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return prefixQueries.count
        }
    }

    // MARK: - Bundle-id evidence

    @Test("Bundle id resolved absent is safe with parentAppMissing")
    func bundleIDMissingIsSafe() {
        let plist = LaunchdPlist(label: "com.acme.helper", program: "/Applications/Acme.app/Contents/MacOS/helper")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/acme.plist", plist: plist),
        ]
        let resolver = CountingOwningAppResolver(installedResult: false)
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            resolverMap: [
                "/Applications/Acme.app/Contents/MacOS/helper": BinaryIdentity(
                    binaryPath: "/Applications/Acme.app/Contents/MacOS/helper",
                    bundlePath: "/Applications/Acme.app",
                    bundleIdentifier: "com.acme.app",
                    vendor: .thirdPartyKnown
                ),
            ],
            existingFiles: ["/Applications/Acme.app/Contents/MacOS/helper"],
            appResolver: resolver
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.safety == .safe)
        #expect(item?.reasons.contains(.parentAppMissing) == true)
    }

    @Test("Two items sharing a bundle id resolve isInstalled exactly once (memo)")
    func bundleIDLookupMemoized() {
        let plist1 = LaunchdPlist(label: "com.acme.one", program: "/Applications/Acme.app/Contents/MacOS/one")
        let plist2 = LaunchdPlist(label: "com.acme.two", program: "/Applications/Acme.app/Contents/MacOS/two")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/one.plist", plist: plist1),
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/two.plist", plist: plist2),
        ]
        let identity1 = BinaryIdentity(
            binaryPath: "/Applications/Acme.app/Contents/MacOS/one",
            bundlePath: "/Applications/Acme.app",
            bundleIdentifier: "com.acme.app",
            vendor: .thirdPartyKnown
        )
        let identity2 = BinaryIdentity(
            binaryPath: "/Applications/Acme.app/Contents/MacOS/two",
            bundlePath: "/Applications/Acme.app",
            bundleIdentifier: "com.acme.app",
            vendor: .thirdPartyKnown
        )
        let resolver = CountingOwningAppResolver(installedResult: false)
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            resolverMap: [
                "/Applications/Acme.app/Contents/MacOS/one": identity1,
                "/Applications/Acme.app/Contents/MacOS/two": identity2,
            ],
            existingFiles: [
                "/Applications/Acme.app/Contents/MacOS/one",
                "/Applications/Acme.app/Contents/MacOS/two",
            ],
            appResolver: resolver
        )
        let scan = scanner.scan()
        #expect(scan.items.count == 2)
        #expect(resolver.installedCallCount == 1)
    }

    // MARK: - Vendor-prefix heuristic evidence

    @Test("Well-known vendor label with no enclosing bundle id and missing prefix is review")
    func vendorPrefixMissingIsReview() {
        let plist = LaunchdPlist(
            label: "com.valvesoftware.steamclean",
            program: "/usr/local/bin/steamclean"
        )
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/steam.plist", plist: plist),
        ]
        let resolver = CountingOwningAppResolver(prefixResult: false)
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            resolverMap: [
                "/usr/local/bin/steamclean": BinaryIdentity(binaryPath: "/usr/local/bin/steamclean", vendor: .unsigned),
            ],
            existingFiles: ["/usr/local/bin/steamclean"],
            appResolver: resolver
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.safety == .review)
        #expect(item?.reasons.contains(.parentAppLikelyMissing) == true)
        #expect(resolver.prefixCallCount == 1)
    }

    @Test("Two items sharing a vendor org prefix resolve isAnyAppInstalled exactly once (memo)")
    func vendorPrefixLookupMemoized() {
        let plist1 = LaunchdPlist(label: "com.valvesoftware.steamclean", program: "/usr/local/bin/steamclean")
        let plist2 = LaunchdPlist(label: "com.valvesoftware.steamerrorreporter", program: "/usr/local/bin/steamerr")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/steam1.plist", plist: plist1),
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/steam2.plist", plist: plist2),
        ]
        let resolver = CountingOwningAppResolver(prefixResult: false)
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            resolverMap: [
                "/usr/local/bin/steamclean": BinaryIdentity(binaryPath: "/usr/local/bin/steamclean", vendor: .unsigned),
                "/usr/local/bin/steamerr": BinaryIdentity(binaryPath: "/usr/local/bin/steamerr", vendor: .unsigned),
            ],
            existingFiles: ["/usr/local/bin/steamclean", "/usr/local/bin/steamerr"],
            appResolver: resolver
        )
        let scan = scanner.scan()
        #expect(scan.items.count == 2)
        #expect(resolver.prefixCallCount == 1)
    }

    // MARK: - Skip guards

    @Test("Personal namespace label never triggers the resolver")
    func personalNamespaceSkipsResolver() {
        let plist = LaunchdPlist(label: "com.jason.memex.sync", program: "/usr/local/bin/sync")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/sync.plist", plist: plist),
        ]
        let resolver = CountingOwningAppResolver()
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: ["/usr/local/bin/sync"],
            appResolver: resolver
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.safety == .review)
        #expect(item?.reasons.contains(.parentAppMissing) == false)
        #expect(item?.reasons.contains(.parentAppLikelyMissing) == false)
        #expect(resolver.installedCallCount == 0)
        #expect(resolver.prefixCallCount == 0)
    }

    @Test("Apple-labeled item never triggers the resolver")
    func appleLabelSkipsResolver() {
        let plist = LaunchdPlist(label: "com.apple.something", program: "/usr/libexec/something")
        let launchd = [
            LaunchdItem(domain: .systemDaemon, plistPath: "/Library/LaunchDaemons/apple.plist", plist: plist),
        ]
        let resolver = CountingOwningAppResolver()
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: ["/usr/libexec/something"],
            appResolver: resolver
        )
        _ = scanner.scan()
        #expect(resolver.installedCallCount == 0)
        #expect(resolver.prefixCallCount == 0)
    }

    @Test("Missing executable never triggers the resolver but still classifies as orphaned/safe")
    func missingExecutableSkipsResolver() {
        let plist = LaunchdPlist(
            label: "com.acme.ghost",
            program: "/Applications/Ghost.app/Contents/MacOS/ghost"
        )
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/ghost.plist", plist: plist),
        ]
        let resolver = CountingOwningAppResolver()
        let scanner = makeScanner(
            launchd: launchd,
            login: .empty,
            existingFiles: [], // binary missing
            appResolver: resolver
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.safety == .safe)
        #expect(item?.reasons.contains(.orphaned) == true)
        #expect(resolver.installedCallCount == 0)
        #expect(resolver.prefixCallCount == 0)
    }

    // MARK: - labelOrgPrefix

    @Test("labelOrgPrefix extracts the first two reverse-DNS components, lowercased")
    func labelOrgPrefixExtraction() {
        #expect(DefaultBackgroundItemScanner.labelOrgPrefix("com.valvesoftware.steamclean") == "com.valvesoftware")
        #expect(DefaultBackgroundItemScanner.labelOrgPrefix("Handy") == nil)
        #expect(DefaultBackgroundItemScanner.labelOrgPrefix("com.foo") == nil)
        #expect(DefaultBackgroundItemScanner.labelOrgPrefix("COM.Adobe.GC.Invoker-1.0") == "com.adobe")
    }

    // MARK: - Helpers

    private func makeScanner(
        launchd: [LaunchdItem],
        login: LoginItemEnumeration,
        resolverMap: [String: BinaryIdentity] = [:],
        existingFiles: Set<String> = [],
        appResolver: any OwningAppResolving
    ) -> DefaultBackgroundItemScanner {
        DefaultBackgroundItemScanner(
            launchdIndex: StubLaunchdIndex(items: launchd),
            loginItems: StubLoginItems(enumeration: login),
            resolver: StubResolver(map: resolverMap),
            classifier: BackgroundItemSafetyClassifier(),
            explainer: BackgroundItemExplainer(),
            runtimeProvider: NilStateRuntimeProvider(),
            appResolver: appResolver,
            fileExists: { existingFiles.contains($0) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}
