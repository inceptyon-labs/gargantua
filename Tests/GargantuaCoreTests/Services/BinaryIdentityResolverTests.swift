import Foundation
import Testing
@testable import GargantuaCore

private struct StubBundleReader: AppBundleReading {
    let metadata: [String: AppBundleMetadata]

    func readMetadata(bundleURL: URL) -> AppBundleMetadata? {
        metadata[bundleURL.path]
    }

    func sizeOnDisk(bundleURL: URL) -> Int64? { nil }
}

private final class StubDetailedVerifier: DetailedCodeSignatureVerifying, @unchecked Sendable {
    var details: [String: CodeSignatureDetails]
    var detailsCallCount: [String: Int] = [:]

    init(details: [String: CodeSignatureDetails]) {
        self.details = details
    }

    func verify(bundleURL: URL) -> CodeSignatureInfo {
        let d = details[bundleURL.path] ?? .unknown
        return CodeSignatureInfo(valid: d.valid, teamIdentifier: d.teamIdentifier)
    }

    func verifyDetails(bundleURL: URL) -> CodeSignatureDetails {
        detailsCallCount[bundleURL.path, default: 0] += 1
        return details[bundleURL.path] ?? .unknown
    }
}

@Suite("BinaryIdentityResolver")
struct BinaryIdentityResolverTests {

    @Test("The identity cache stays bounded across many distinct binaries")
    func cacheIsBounded() {
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: StubDetailedVerifier(details: [:]),
            registry: .default,
            modificationDate: { _ in nil }
        )
        for index in 0 ... DefaultBinaryIdentityResolver.cacheLimit {
            _ = resolver.resolve(binaryPath: "/tmp/gargantua-bin-\(index)")
        }
        #expect(resolver.cachedBinaryCount <= DefaultBinaryIdentityResolver.cacheLimit)
    }

    // MARK: - Bundle walk-up

    @Test("Walk-up finds .app from helper executable inside Contents/MacOS")
    func walkUpFindsApp() {
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: StubDetailedVerifier(details: [:]),
            registry: .default
        )
        let url = resolver.enclosingBundleURL(
            for: "/Applications/Foo.app/Contents/MacOS/Foo"
        )
        #expect(url?.path == "/Applications/Foo.app")
    }

    @Test("Walk-up finds nested .appex inside an .app")
    func walkUpFindsNestedAppex() {
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: StubDetailedVerifier(details: [:]),
            registry: .default
        )
        let url = resolver.enclosingBundleURL(
            for: "/Applications/Foo.app/Contents/PlugIns/Bar.appex/Contents/MacOS/Bar"
        )
        // Walk-up should find the *nearest* enclosing bundle — the .appex.
        #expect(url?.path == "/Applications/Foo.app/Contents/PlugIns/Bar.appex")
    }

    @Test("Walk-up returns nil for /usr/local/bin binaries")
    func walkUpReturnsNilForUnbundled() {
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: StubDetailedVerifier(details: [:]),
            registry: .default
        )
        let url = resolver.enclosingBundleURL(for: "/usr/local/bin/git")
        #expect(url == nil)
    }

    // MARK: - Vendor classification

    @Test("Apple-anchored binary classifies as .apple")
    func appleAnchoredIsApple() {
        let path = "/usr/sbin/cfprefsd"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: nil,
                signingIdentity: "Software Signing",
                isNotarized: nil,
                isAppleAnchor: true,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default
        )

        let identity = resolver.resolve(binaryPath: path)
        #expect(identity.vendor == .apple)
        #expect(identity.signatureValid == true)
    }

    @Test("Developer-ID-signed binary with known team classifies as .thirdPartyKnown")
    func knownThirdPartyClassified() {
        let path = "/Applications/CustomKnown.app"
        let registry = KnownVendorRegistry(entries: [
            KnownVendorEntry(teamIdentifier: "TEAMKN", displayName: "CustomKnown"),
        ])
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "TEAMKN",
                signingIdentity: "Developer ID Application: Custom Inc.",
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [
                path: AppBundleMetadata(
                    bundleID: "com.custom.app",
                    name: "CustomKnown",
                    bundlePath: path
                ),
            ]),
            signatureVerifier: verifier,
            registry: registry
        )

        let identity = resolver.resolve(binaryPath: path + "/Contents/MacOS/CustomKnown")
        #expect(identity.vendor == .thirdPartyKnown)
        #expect(identity.vendorDisplayName == "CustomKnown")
        #expect(identity.bundleIdentifier == "com.custom.app")
        #expect(identity.sensitiveCategories.isEmpty)
    }

    @Test("Valid signature without Apple-generic anchor classifies as .unsigned (anti-spoof)")
    func adHocSignatureWithTeamIDIsNotTrusted() {
        // An ad-hoc / self-signed binary that happens to embed a Team
        // ID-shaped string in its signing dict must NOT be elevated to
        // `thirdPartyKnown` even if the registry has a matching entry.
        let path = "/tmp/spoofed"
        let registry = KnownVendorRegistry(entries: [
            KnownVendorEntry(teamIdentifier: "2BUA8C4S2C", displayName: "1Password",
                             sensitiveCategories: [.passwordManager]),
        ])
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "2BUA8C4S2C",
                signingIdentity: nil,
                isNotarized: nil,
                isAppleAnchor: false,
                isAppleGenericAnchor: false
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: registry
        )

        let identity = resolver.resolve(binaryPath: path)
        #expect(identity.vendor == .unsigned)
        #expect(identity.vendorDisplayName == nil)
        #expect(identity.sensitiveCategories.isEmpty)
    }

    @Test("Developer-ID-signed binary with unknown team classifies as .thirdPartyUnknown")
    func unknownThirdPartyClassified() {
        let path = "/Applications/RandomThing.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "ZZZNOTKNOWN",
                signingIdentity: "Developer ID Application: Random Inc.",
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [
                path: AppBundleMetadata(
                    bundleID: "com.random.app",
                    name: "RandomThing",
                    bundlePath: path
                ),
            ]),
            signatureVerifier: verifier,
            registry: .default
        )

        let identity = resolver.resolve(binaryPath: path + "/Contents/MacOS/RandomThing")
        #expect(identity.vendor == .thirdPartyUnknown)
        #expect(identity.vendorDisplayName == nil)
    }

    @Test("Invalid signature classifies as .unsigned regardless of team")
    func invalidSignatureIsUnsigned() {
        let path = "/Applications/Tampered.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: false,
                teamIdentifier: "UBF8T346G9",
                signingIdentity: nil,
                isNotarized: nil,
                isAppleAnchor: false,
                isAppleGenericAnchor: false
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default
        )

        let identity = resolver.resolve(binaryPath: path)
        #expect(identity.vendor == .unsigned)
        #expect(identity.signatureValid == false)
    }

    @Test("Unevaluable signature classifies as .unsigned")
    func unknownSignatureIsUnsigned() {
        let path = "/tmp/garbage"
        let verifier = StubDetailedVerifier(details: [:]) // returns .unknown
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default
        )

        let identity = resolver.resolve(binaryPath: path)
        #expect(identity.vendor == .unsigned)
        #expect(identity.signatureValid == nil)
    }

    // MARK: - Sensitive vendor flag

    @Test("Sensitive vendor surfaces categories even when properly signed")
    func sensitiveVendorIsFlagged() {
        let path = "/Applications/1Password.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "2BUA8C4S2C",
                signingIdentity: "Developer ID Application: AgileBits Inc.",
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [
                path: AppBundleMetadata(
                    bundleID: "com.1password.1password",
                    name: "1Password",
                    bundlePath: path
                ),
            ]),
            signatureVerifier: verifier,
            registry: .default
        )

        let identity = resolver.resolve(binaryPath: path + "/Contents/MacOS/1Password")
        #expect(identity.vendor == .thirdPartyKnown)
        #expect(identity.isSensitiveVendor)
        #expect(identity.sensitiveCategories == [.passwordManager])
    }
}

@Suite("BinaryIdentityResolver caching")
struct BinaryIdentityResolverCachingTests {

    @Test("Resolver caches identity per binary path")
    func cachesPerPath() {
        let path = "/Applications/Foo.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "TEAM1",
                signingIdentity: nil,
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default
        )

        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")

        #expect(verifier.detailsCallCount[path] == 1,
                "Expected exactly one signature evaluation across 3 calls; got \(verifier.detailsCallCount[path] ?? 0)")
    }

    @Test("clearCache forces re-evaluation")
    func clearCacheReEvaluates() {
        let path = "/Applications/Foo.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "TEAM1",
                signingIdentity: nil,
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default
        )

        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")
        resolver.clearCache()
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")

        #expect(verifier.detailsCallCount[path] == 2)
    }

    @Test("Unchanged mtime reuses the cached identity across passes")
    func stableMtimeHitsCacheWithoutClear() {
        let path = "/Applications/Foo.app"
        let verifier = signedVerifier(for: path)
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default,
            modificationDate: { _ in Date(timeIntervalSince1970: 1_000) }
        )

        // Three passes, no clearCache() — the mtime is stable so the signature
        // is evaluated exactly once. This is the per-keystroke search win.
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")

        #expect(verifier.detailsCallCount[path] == 1)
    }

    @Test("Changed mtime invalidates the cache and re-resolves")
    func changedMtimeReEvaluates() {
        let path = "/Applications/Foo.app"
        let verifier = signedVerifier(for: path)
        let mtimes = MTimeSequence([
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 2_000),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default,
            modificationDate: { mtimes.next($0) }
        )

        // A binary swapped in at the same path (new mtime) must re-resolve even
        // though nothing called clearCache().
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Foo")

        #expect(verifier.detailsCallCount[path] == 2)
    }

    @Test("Missing binary (nil mtime) stays cached")
    func nilMtimeStaysCached() {
        let path = "/Applications/Gone.app"
        let verifier = signedVerifier(for: path)
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [:]),
            signatureVerifier: verifier,
            registry: .default,
            modificationDate: { _ in nil }
        )

        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Gone")
        _ = resolver.resolve(binaryPath: path + "/Contents/MacOS/Gone")

        #expect(verifier.detailsCallCount[path] == 1)
    }

    private func signedVerifier(for path: String) -> StubDetailedVerifier {
        StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "TEAM1",
                signingIdentity: nil,
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
    }
}

/// Hands out a scripted sequence of modification dates, one per `next(_:)`
/// call, clamping to the last element so an over-long test can't trap.
private final class MTimeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let dates: [Date?]
    private var index = 0

    init(_ dates: [Date?]) { self.dates = dates }

    func next(_: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let date = dates[min(index, dates.count - 1)]
        index += 1
        return date
    }
}
