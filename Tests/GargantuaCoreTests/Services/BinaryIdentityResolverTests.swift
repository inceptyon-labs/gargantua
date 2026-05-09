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
        let path = "/Applications/Microsoft Word.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "UBF8T346G9",
                signingIdentity: "Developer ID Application: Microsoft Corporation",
                isNotarized: true,
                isAppleAnchor: false,
                isAppleGenericAnchor: true
            ),
        ])
        let resolver = DefaultBinaryIdentityResolver(
            bundleReader: StubBundleReader(metadata: [
                path: AppBundleMetadata(
                    bundleID: "com.microsoft.Word",
                    name: "Microsoft Word",
                    bundlePath: path
                ),
            ]),
            signatureVerifier: verifier,
            registry: .default
        )

        let identity = resolver.resolve(binaryPath: path + "/Contents/MacOS/Microsoft Word")
        #expect(identity.vendor == .thirdPartyKnown)
        #expect(identity.vendorDisplayName == "Microsoft")
        #expect(identity.bundleIdentifier == "com.microsoft.Word")
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

    // MARK: - Caching

    @Test("Resolver caches identity per binary path")
    func cachesPerPath() {
        let path = "/Applications/Foo.app"
        let verifier = StubDetailedVerifier(details: [
            path: CodeSignatureDetails(
                valid: true,
                teamIdentifier: "UBF8T346G9",
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
                teamIdentifier: "UBF8T346G9",
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
}
