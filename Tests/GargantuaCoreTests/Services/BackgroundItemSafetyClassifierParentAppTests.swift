import Foundation
import Testing
@testable import GargantuaCore

// Owning-app orphan evidence rules (3.5 parentAppMissing, 3.75
// parentAppLikelyMissing) — split from BackgroundItemSafetyClassifierTests
// to keep that suite's type body under the 300-line SwiftLint limit.
@Suite("BackgroundItemSafetyClassifier — parent app evidence")
struct SafetyClassifierParentAppTests {

    private let classifier = BackgroundItemSafetyClassifier()

    // MARK: - Owning app orphan evidence

    @Test("Bundle evidence resolved absent is safe with parentAppMissing, not orphaned")
    func parentAppMissingIsSafe() {
        let identity = makeIdentity(vendor: .thirdPartyKnown, bundlePath: "/Applications/Ghost.app")
        let input = BackgroundItemClassifierInput(
            label: "com.example.ghost",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.ghost.plist",
            executablePath: "/Applications/Ghost.app/Contents/MacOS/ghost",
            identity: identity,
            executableExists: true,
            parentAppInstalled: false,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.reasons.contains(.parentAppMissing))
        // The executable exists — the "orphaned executable" chip would lie.
        #expect(!result.reasons.contains(.orphaned))
    }

    @Test("Owning app present adds no evidence reason and keeps the known-vendor safe path")
    func parentAppInstalledTrueKeepsVendorSafePath() {
        let identity = makeIdentity(vendor: .thirdPartyKnown, bundlePath: "/Applications/Present.app")
        let input = BackgroundItemClassifierInput(
            label: "com.present.helper",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.present.helper.plist",
            executablePath: "/Applications/Present.app/Contents/MacOS/helper",
            identity: identity,
            executableExists: true,
            parentAppInstalled: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(!result.reasons.contains(.parentAppMissing))
        #expect(!result.reasons.contains(.parentAppLikelyMissing))
    }

    @Test("Well-known vendor label with no installed app is review with parentAppLikelyMissing")
    func knownVendorAppMissingIsReview() {
        let input = BackgroundItemClassifierInput(
            label: "com.acme.helper",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.acme.helper.plist",
            executablePath: "/usr/local/bin/helper",
            identity: nil,
            executableExists: true,
            knownVendorAppMissing: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.parentAppLikelyMissing))
    }

    @Test("Personal job with no orphan evidence carries neither new reason")
    func personalJobHasNeitherOrphanReason() {
        let identity = makeIdentity(vendor: .unsigned)
        let input = BackgroundItemClassifierInput(
            label: "com.jason-shaped.tool",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.jason-shaped.tool.plist",
            executablePath: "/usr/local/bin/tool",
            identity: identity,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(!result.reasons.contains(.parentAppMissing))
        #expect(!result.reasons.contains(.parentAppLikelyMissing))
    }

    @Test("Vendor-missing heuristic overrides the known-vendor safe shape — never safe alone")
    func knownVendorAppMissingNeverSafe() {
        let identity = makeIdentity(vendor: .thirdPartyKnown, bundlePath: "/Applications/Known.app")
        let input = BackgroundItemClassifierInput(
            label: "com.known.helper",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.known.helper.plist",
            executablePath: "/Applications/Known.app/Contents/MacOS/helper",
            identity: identity,
            executableExists: true,
            knownVendorAppMissing: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.parentAppLikelyMissing))
    }

    @Test("Apple system rule takes precedence over parentAppInstalled evidence")
    func appleSystemBeatsParentAppMissing() {
        let input = BackgroundItemClassifierInput(
            label: "com.apple.ghost",
            source: .launchDaemon,
            plistPath: "/tmp/com.apple.ghost.plist",
            executablePath: "/usr/libexec/ghost",
            identity: nil,
            executableExists: true,
            parentAppInstalled: false,
            plist: nil
        )
        #expect(classifier.classify(input).safety == .protected_)
    }

    @Test("Sensitive vendor rule takes precedence over parentAppInstalled evidence")
    func sensitiveVendorBeatsParentAppMissing() {
        let identity = makeIdentity(vendor: .thirdPartyKnown, sensitiveCategories: [.vpn])
        let input = BackgroundItemClassifierInput(
            label: "com.acme.vpn.helper",
            source: .launchDaemon,
            plistPath: "/tmp/com.acme.vpn.helper.plist",
            executablePath: "/Applications/AcmeVPN.app/Contents/MacOS/helper",
            identity: identity,
            executableExists: true,
            parentAppInstalled: false,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.sensitiveVendor))
    }

    @Test("Missing-executable orphan rule fires before parentAppInstalled is checked")
    func executableMissingBeatsParentAppMissing() {
        let identity = makeIdentity(vendor: .thirdPartyKnown, bundlePath: "/Applications/Foo.app")
        let input = BackgroundItemClassifierInput(
            label: "com.example.foo",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.foo.plist",
            executablePath: "/Applications/Foo.app/Contents/MacOS/foo",
            identity: identity,
            executableExists: false,
            parentAppInstalled: false,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.reasons.contains(.orphaned))
        #expect(result.reasons.contains(.orphanedVendor))
        #expect(!result.reasons.contains(.parentAppMissing))
    }

    // MARK: - Helpers

    private func makeIdentity(
        vendor: VendorClassification,
        bundlePath: String? = "/Applications/Stub.app",
        sensitiveCategories: Set<SensitiveVendorCategory> = []
    ) -> BinaryIdentity {
        BinaryIdentity(
            binaryPath: "/tmp/stub",
            bundlePath: bundlePath,
            bundleIdentifier: "com.stub.app",
            bundleName: "Stub",
            vendor: vendor,
            vendorDisplayName: vendor == .thirdPartyKnown ? "Stub Vendor" : nil,
            sensitiveCategories: sensitiveCategories
        )
    }
}
