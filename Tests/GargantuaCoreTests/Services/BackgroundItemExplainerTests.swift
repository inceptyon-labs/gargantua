import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemExplainer")
struct BackgroundItemExplainerTests {

    private let explainer = BackgroundItemExplainer()

    @Test("Apple-signed system daemon mentions Apple and runs-at-load")
    func appleDaemon() {
        let plist = LaunchdPlist(
            label: "com.apple.fooSvc",
            program: "/usr/libexec/foo",
            runAtLoad: true
        )
        let identity = BinaryIdentity(
            binaryPath: "/usr/libexec/foo",
            bundleName: "Foo",
            vendor: .apple
        )
        let result = explainer.explain(
            source: .launchDaemon,
            plist: plist,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("LaunchDaemon (root)"))
        #expect(result.contains("signed by Apple"))
        #expect(result.contains("runs at load"))
    }

    @Test("Known-vendor agent mentions vendor display name")
    func knownVendorAgent() {
        let plist = LaunchdPlist(
            label: "com.adobe.update",
            program: "/Applications/Adobe Updater.app/Contents/MacOS/updater",
            runAtLoad: true,
            startInterval: 86_400
        )
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Adobe Updater.app/Contents/MacOS/updater",
            bundlePath: "/Applications/Adobe Updater.app",
            bundleName: "Adobe Updater",
            teamIdentifier: "ABCDE12345",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Adobe"
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("signed by Adobe"))
        #expect(result.contains("ships with Adobe Updater"))
        #expect(result.contains("1 day"))
    }

    @Test("Unknown developer surfaces team ID")
    func unknownDeveloperShowsTeam() {
        let plist = LaunchdPlist(label: "com.mystery.thing", program: "/Applications/Mystery.app/Contents/MacOS/mystery")
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Mystery.app/Contents/MacOS/mystery",
            bundlePath: "/Applications/Mystery.app",
            bundleName: "Mystery",
            teamIdentifier: "ZZZZZ99999",
            vendor: .thirdPartyUnknown
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("signed by unknown team ZZZZZ99999"))
    }

    @Test("Unsigned binary explanation mentions unsigned status")
    func unsignedBinary() {
        let plist = LaunchdPlist(label: "com.local.thing", program: "/usr/local/bin/thing")
        let identity = BinaryIdentity(binaryPath: "/usr/local/bin/thing", vendor: .unsigned)
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("unsigned"))
    }

    @Test("Missing target binary surfaces 'target binary missing'")
    func missingTarget() {
        let plist = LaunchdPlist(label: "com.gone.thing", program: "/Applications/Gone.app/Contents/MacOS/gone")
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Gone.app/Contents/MacOS/gone",
            bundleName: "Gone",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Gone Inc"
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: identity,
            executableExists: false
        )
        #expect(result.contains("target binary missing"))
    }

    @Test("Mach service trigger appears in explanation")
    func machServiceTrigger() {
        let plist = LaunchdPlist(
            label: "com.example.svc",
            program: "/usr/local/bin/svc",
            machServices: ["com.example.svc.endpoint"]
        )
        let result = explainer.explain(
            source: .launchDaemon,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("on Mach service request"))
    }

    @Test("Watch path trigger appears in explanation")
    func watchPathTrigger() {
        let plist = LaunchdPlist(
            label: "com.example.watch",
            program: "/usr/local/bin/watch",
            watchPaths: ["/tmp/incoming"]
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("on path change"))
    }

    @Test("Login item without plist still produces a coherent explanation")
    func loginItemNoPlist() {
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Foo.app",
            bundleName: "Foo",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Foo Co"
        )
        let result = explainer.explain(
            source: .loginItem,
            plist: nil,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("Login Item"))
        #expect(result.contains("signed by Foo Co"))
        #expect(result.contains("ships with Foo"))
    }

    @Test("StartInterval formats hours correctly")
    func intervalHours() {
        let plist = LaunchdPlist(label: "com.example.cron", startInterval: 7200)
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("every 2 hours"))
    }

    @Test("StartInterval falls back to seconds when not divisible")
    func intervalSeconds() {
        let plist = LaunchdPlist(label: "com.example.cron", startInterval: 45)
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("every 45s"))
    }
}
