import Foundation
import Testing
@testable import GargantuaCore

// Wide test surface — every safety branch (Apple system, sensitive vendor,
// orphaned, known-with-bundle, unsigned, login items) plus the derived-reason
// matrix lives here. Splitting would scatter tests that share helpers.
@Suite("BackgroundItemSafetyClassifier")
// swiftlint:disable:next type_body_length
struct BackgroundItemSafetyClassifierTests {

    private let classifier = BackgroundItemSafetyClassifier()

    // MARK: - Apple system rules

    @Test("com.apple.* label is protected regardless of identity")
    func appleLabelIsProtected() {
        let input = makeInput(
            label: "com.apple.MobileBackup",
            source: .launchDaemon,
            executablePath: "/usr/libexec/mobilebackup"
        )
        let result = classifier.classify(input)
        #expect(result.safety == .protected_)
        #expect(result.reasons.contains(.system))
    }

    @Test("Apple-signed binary in /System/ is protected")
    func appleSignedSystemBinaryIsProtected() {
        let identity = makeIdentity(
            vendor: .apple,
            bundlePath: "/System/Library/CoreServices/Foo.framework"
        )
        let input = makeInput(
            label: "com.example.daemon",
            source: .launchDaemon,
            executablePath: "/System/Library/Foo",
            identity: identity
        )
        #expect(classifier.classify(input).safety == .protected_)
    }

    @Test("Apple-signed binary in /usr/ is protected")
    func appleSignedUsrBinaryIsProtected() {
        let identity = makeIdentity(vendor: .apple)
        let input = makeInput(
            label: "com.example.helper",
            source: .launchDaemon,
            executablePath: "/usr/libexec/foo",
            identity: identity
        )
        #expect(classifier.classify(input).safety == .protected_)
    }

    @Test("Apple-signed binary outside /System/ or /usr/ is NOT auto-protected")
    func appleSignedUserlandIsNotAutoProtected() {
        let identity = makeIdentity(vendor: .apple)
        let input = makeInput(
            label: "com.example.tool",
            source: .userLaunchAgent,
            executablePath: "/Applications/Foo.app/Contents/MacOS/foo",
            identity: identity
        )
        // Not protected — falls through to default review
        #expect(classifier.classify(input).safety == .review)
    }

    // MARK: - Sensitive vendor

    @Test("Sensitive vendor (VPN) defaults to review even when valid signature")
    func sensitiveVendorIsReview() {
        let identity = makeIdentity(
            vendor: .thirdPartyKnown,
            sensitiveCategories: [.vpn]
        )
        let input = makeInput(
            label: "com.acme.vpn.helper",
            source: .launchDaemon,
            executablePath: "/Applications/AcmeVPN.app/Contents/MacOS/helper",
            identity: identity
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.sensitiveVendor))
    }

    @Test("Sensitive vendor stays review even when binary is missing")
    func sensitiveVendorReviewWhenOrphaned() {
        let identity = makeIdentity(
            vendor: .thirdPartyKnown,
            sensitiveCategories: [.passwordManager]
        )
        let input = makeInput(
            label: "com.example.pm",
            source: .userLaunchAgent,
            executablePath: "/Applications/PM.app/Contents/MacOS/pm",
            identity: identity,
            executableExists: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.sensitiveVendor))
        // Sensitive vendor short-circuits; orphan reason isn't added because
        // sensitivity beats orphan-cleanup.
        #expect(!result.reasons.contains(.orphaned))
    }

    // MARK: - Orphaned

    @Test("Missing executable is safe with orphaned reason")
    func orphanedIsSafe() {
        let identity = makeIdentity(vendor: .thirdPartyUnknown, bundlePath: nil)
        let input = makeInput(
            label: "com.example.gone",
            source: .userLaunchAgent,
            executablePath: "/Applications/Vanished.app/Contents/MacOS/vanished",
            identity: identity,
            executableExists: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.reasons.contains(.orphaned))
    }

    @Test("Orphaned with vendor bundle records orphanedVendor reason")
    func orphanedVendorReason() {
        let identity = makeIdentity(
            vendor: .thirdPartyKnown,
            bundlePath: "/Applications/Foo.app"
        )
        let input = makeInput(
            label: "com.example.foo",
            source: .userLaunchAgent,
            executablePath: "/Applications/Foo.app/Contents/MacOS/foo",
            identity: identity,
            executableExists: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.reasons.contains(.orphaned))
        #expect(result.reasons.contains(.orphanedVendor))
    }

    // MARK: - Known vendor with parent

    @Test("Known non-sensitive vendor with parent bundle is safe")
    func knownVendorWithParentIsSafe() {
        let identity = makeIdentity(
            vendor: .thirdPartyKnown,
            bundlePath: "/Applications/Adobe Updater.app"
        )
        let input = makeInput(
            label: "com.adobe.updater",
            source: .userLaunchAgent,
            executablePath: "/Applications/Adobe Updater.app/Contents/MacOS/updater",
            identity: identity
        )
        #expect(classifier.classify(input).safety == .safe)
    }

    @Test("Known vendor without bundle path falls back to review")
    func knownVendorWithoutParentIsReview() {
        let identity = makeIdentity(
            vendor: .thirdPartyKnown,
            bundlePath: nil
        )
        let input = makeInput(
            label: "com.example.tool",
            source: .userLaunchAgent,
            executablePath: "/usr/local/bin/tool",
            identity: identity
        )
        // No bundle context — defaults to review.
        #expect(classifier.classify(input).safety == .review)
    }

    // MARK: - Unsigned

    @Test("Unsigned binary is review with unsigned reason")
    func unsignedIsReview() {
        let identity = makeIdentity(vendor: .unsigned)
        let input = makeInput(
            label: "com.suspicious.thing",
            source: .userLaunchAgent,
            executablePath: "/tmp/foo",
            identity: identity
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.unsigned))
    }

    @Test("Unknown developer (third-party-unknown, signed, present) is review")
    func unknownDeveloperIsReview() {
        let identity = makeIdentity(
            vendor: .thirdPartyUnknown,
            bundlePath: "/Applications/Mystery.app"
        )
        let input = makeInput(
            label: "com.mystery.thing",
            source: .userLaunchAgent,
            executablePath: "/Applications/Mystery.app/Contents/MacOS/mystery",
            identity: identity
        )
        #expect(classifier.classify(input).safety == .review)
    }

    // MARK: - Derived reasons

    @Test("Mach service registration adds listensForRequests reason")
    func machServiceListens() {
        let plist = LaunchdPlist(
            label: "com.example.svc",
            program: "/usr/local/bin/svc",
            machServices: ["com.example.svc.endpoint"]
        )
        let identity = makeIdentity(vendor: .thirdPartyKnown, bundlePath: "/Applications/Svc.app")
        let input = BackgroundItemClassifierInput(
            label: "com.example.svc",
            source: .launchDaemon,
            plistPath: "/Library/LaunchDaemons/com.example.svc.plist",
            executablePath: "/usr/local/bin/svc",
            identity: identity,
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(result.reasons.contains(.listensForRequests))
    }

    @Test("RunAtLoad + KeepAlive marks persistentlyRunning")
    func keepAliveAndRunAtLoad() {
        let plist = LaunchdPlist(label: "com.example.always", keepAlive: true, runAtLoad: true)
        let input = BackgroundItemClassifierInput(
            label: "com.example.always",
            source: .userLaunchAgent,
            plistPath: "/Library/LaunchAgents/com.example.always.plist",
            executablePath: "/usr/local/bin/always",
            identity: makeIdentity(vendor: .unsigned),
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(result.reasons.contains(.persistentlyRunning))
    }

    @Test("StartInterval marks scheduled")
    func startIntervalScheduled() {
        let plist = LaunchdPlist(label: "com.example.cron", startInterval: 3600)
        let input = BackgroundItemClassifierInput(
            label: "com.example.cron",
            source: .userLaunchAgent,
            plistPath: "/Library/LaunchAgents/com.example.cron.plist",
            executablePath: "/usr/local/bin/cron",
            identity: makeIdentity(vendor: .unsigned),
            executableExists: true,
            plist: plist
        )
        #expect(classifier.classify(input).reasons.contains(.scheduled))
    }

    @Test("Disabled plist key adds disabledFlag reason")
    func disabledFlag() {
        let plist = LaunchdPlist(label: "com.example.off", disabled: true)
        let input = BackgroundItemClassifierInput(
            label: "com.example.off",
            source: .userLaunchAgent,
            plistPath: "/Library/LaunchAgents/com.example.off.plist",
            executablePath: "/usr/local/bin/off",
            identity: makeIdentity(vendor: .unsigned),
            executableExists: true,
            plist: plist
        )
        #expect(classifier.classify(input).reasons.contains(.disabledFlag))
    }

    // MARK: - Login items

    @Test("Login item with no identity defaults to review")
    func loginItemNoIdentityIsReview() {
        let input = BackgroundItemClassifierInput(
            label: "com.example.app",
            source: .loginItem,
            plistPath: nil,
            executablePath: nil,
            identity: nil,
            executableExists: false,
            plist: nil
        )
        #expect(classifier.classify(input).safety == .review)
    }

    // MARK: - Helpers

    private func makeInput(
        label: String,
        source: BackgroundItemSource,
        executablePath: String?,
        identity: BinaryIdentity? = nil,
        executableExists: Bool = true
    ) -> BackgroundItemClassifierInput {
        BackgroundItemClassifierInput(
            label: label,
            source: source,
            plistPath: "/tmp/\(label).plist",
            executablePath: executablePath,
            identity: identity,
            executableExists: executableExists,
            plist: LaunchdPlist(label: label, program: executablePath)
        )
    }

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
