import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessSafetyClassifier")
struct ProcessSafetyClassifierTests {

    private let classifier = ProcessSafetyClassifier()

    // MARK: - Apple system

    @Test("Apple-signed binary under /System is protected")
    func appleSystemUnderSystem() {
        let identity = BinaryIdentity(
            binaryPath: "/System/Library/CoreServices/Foo",
            bundlePath: "/System/Library/CoreServices/Foo.app",
            vendor: .apple
        )
        let input = ProcessClassifierInput(
            command: "Foo",
            executablePath: "/System/Library/CoreServices/Foo",
            uid: 0,
            identity: identity,
            launchSource: .userSession,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .protected_)
        #expect(result.reasons.contains(.system))
        #expect(result.reasons.contains(.rootProcess))
        #expect(result.explanation.contains("Apple system process"))
    }

    @Test("Apple-signed binary under /usr is protected")
    func appleSystemUnderUsr() {
        let identity = BinaryIdentity(binaryPath: "/usr/sbin/foo", vendor: .apple)
        let input = ProcessClassifierInput(
            command: "foo",
            executablePath: "/usr/sbin/foo",
            uid: 0,
            identity: identity,
            launchSource: .unknown,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        #expect(classifier.classify(input).safety == .protected_)
    }

    @Test("Apple vendor outside /System and /usr does not auto-protect")
    func appleVendorOutsideSystemPaths() {
        // Defensive: even with vendor=.apple, a path outside /System or /usr
        // shouldn't get protected — the rule requires both anchor and path.
        let identity = BinaryIdentity(binaryPath: "/Applications/SomethingApple.app", vendor: .apple)
        let input = ProcessClassifierInput(
            command: "Something",
            executablePath: "/Applications/SomethingApple.app/Contents/MacOS/Something",
            uid: 501,
            identity: identity,
            launchSource: .userSession,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        #expect(classifier.classify(input).safety != .protected_)
    }

    // MARK: - Sensitive vendor

    @Test("Sensitive vendor maps to review regardless of signature")
    func sensitiveVendor() {
        let identity = BinaryIdentity(
            binaryPath: "/Applications/VPN.app/Contents/MacOS/vpn",
            bundlePath: "/Applications/VPN.app",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "VPNCo",
            sensitiveCategories: [.vpn]
        )
        let input = ProcessClassifierInput(
            command: "vpn",
            executablePath: "/Applications/VPN.app/Contents/MacOS/vpn",
            uid: 0,
            identity: identity,
            launchSource: .launchd(domain: .systemDaemon, label: "com.vpn.daemon", plistPath: "/Library/LaunchDaemons/vpn.plist"),
            launchConfidence: .exact,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.sensitiveVendor))
    }

    // MARK: - Foreground app

    @Test("Foreground app source maps to review")
    func foregroundApp() {
        let input = ProcessClassifierInput(
            command: "Safari",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            uid: 501,
            identity: BinaryIdentity(binaryPath: "/Applications/Safari.app", vendor: .thirdPartyUnknown),
            launchSource: .foregroundApp,
            launchConfidence: .heuristic,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.foregroundApp))
    }

    // MARK: - Orphaned

    @Test("Orphaned launchd source → safe + orphaned reason")
    func orphanedSource() {
        let identity = BinaryIdentity(
            binaryPath: "/usr/local/bin/zombie",
            teamIdentifier: "ZZZZZ",
            vendor: .thirdPartyUnknown
        )
        let input = ProcessClassifierInput(
            command: "zombie",
            executablePath: "/usr/local/bin/zombie",
            uid: 501,
            identity: identity,
            launchSource: .launchd(domain: .userAgent, label: "com.zombie.helper", plistPath: "/p.plist"),
            launchConfidence: .path,
            launchSourceOrphaned: true
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.reasons.contains(.orphaned))
    }

    @Test("Orphaned never overrides sensitive vendor")
    func orphanedDoesNotOverrideSensitive() {
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Pwm.app",
            vendor: .thirdPartyKnown,
            sensitiveCategories: [.passwordManager]
        )
        let input = ProcessClassifierInput(
            command: "pwm",
            executablePath: "/Applications/Pwm.app",
            uid: 501,
            identity: identity,
            launchSource: .launchd(domain: .userAgent, label: "com.pwm.helper", plistPath: "/p.plist"),
            launchConfidence: .exact,
            launchSourceOrphaned: true
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.sensitiveVendor))
    }

    // MARK: - Known third-party + launchd → safe

    @Test("Known third-party vendor with launchd source → safe")
    func knownVendorWithLaunchd() {
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Acme.app/Contents/MacOS/helper",
            bundlePath: "/Applications/Acme.app",
            bundleName: "Acme",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Acme Corp"
        )
        let input = ProcessClassifierInput(
            command: "helper",
            executablePath: "/Applications/Acme.app/Contents/MacOS/helper",
            uid: 501,
            identity: identity,
            launchSource: .launchd(domain: .userAgent, label: "com.acme.helper", plistPath: "/p.plist"),
            launchConfidence: .exact,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.explanation.contains("Acme Corp"))
        #expect(result.explanation.contains("will relaunch"))
    }

    @Test("Known third-party vendor without launchd source does NOT auto-safe")
    func knownVendorWithoutLaunchd() {
        // Without a launchd-managed source, a foreground / user-session
        // helper from a known vendor still warrants review — we don't know
        // whether killing it strands real work.
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Acme.app",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Acme Corp"
        )
        let input = ProcessClassifierInput(
            command: "Acme",
            executablePath: "/Applications/Acme.app/Contents/MacOS/Acme",
            uid: 501,
            identity: identity,
            launchSource: .userSession,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        #expect(classifier.classify(input).safety == .review)
    }

    // MARK: - Unsigned

    @Test("Unsigned binary → review with unsigned reason")
    func unsignedBinary() {
        let identity = BinaryIdentity(binaryPath: "/tmp/strange", vendor: .unsigned)
        let input = ProcessClassifierInput(
            command: "strange",
            executablePath: "/tmp/strange",
            uid: 501,
            identity: identity,
            launchSource: .userSession,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.unsigned))
    }

    // MARK: - Root reason

    @Test("Root processes always carry the rootProcess reason")
    func rootReasonCarriesAcross() {
        let identity = BinaryIdentity(binaryPath: "/bin/foo", vendor: .thirdPartyUnknown)
        let input = ProcessClassifierInput(
            command: "foo",
            executablePath: "/bin/foo",
            uid: 0,
            identity: identity,
            launchSource: .unknown,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.reasons.contains(.rootProcess))
    }

    // MARK: - Default

    @Test("Default with no identity falls back to review")
    func defaultNoIdentity() {
        let input = ProcessClassifierInput(
            command: "mystery",
            executablePath: nil,
            uid: 501,
            identity: nil,
            launchSource: .unknown,
            launchConfidence: .unknown,
            launchSourceOrphaned: false
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(!result.explanation.isEmpty)
    }
}
