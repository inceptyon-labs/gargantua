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
        #expect(result.contains("starts at boot"))
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

    @Test("Mach service trigger appears in explanation and surfaces disable-impact")
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
        #expect(result.contains("starts on a Mach-service or socket request"))
        #expect(result.contains("clients may fail to reach it if disabled"))
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
        #expect(result.contains("runs when watched paths change"))
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

/// Split from `BackgroundItemExplainerTests` to keep the type body under the
/// SwiftLint 300-line limit — covers calendar narration, trigger phrasing,
/// and the disable-impact segment.
@Suite("BackgroundItemExplainer narration & impact")
struct BackgroundItemExplainerNarrationTests {

    private let explainer = BackgroundItemExplainer()

    @Test("Real com.jason.tm-exclusions shape narrates monthly-on-day with time")
    func calendarMonthlyViaExplain() {
        let plist = LaunchdPlist(
            label: "com.jason.tm-exclusions",
            program: "/usr/local/bin/tm-exclusions",
            startCalendarInterval: [LaunchdCalendarInterval(minute: 15, hour: 12, day: 1)]
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("monthly on day 1 at 12:15"))
    }

    @Test("calendarPart formats a daily interval")
    func calendarPartDaily() {
        let interval = LaunchdCalendarInterval(minute: 0, hour: 2)
        #expect(BackgroundItemExplainer.calendarPart([interval]) == "daily at 02:00")
    }

    @Test("calendarPart drops out-of-range fields instead of printing garbage")
    func calendarPartValidatesRanges() {
        // hour 25 dropped → minute-only "hourly at :30"
        #expect(BackgroundItemExplainer.calendarPart(
            [LaunchdCalendarInterval(minute: 30, hour: 25)]
        ) == "hourly at :30")
        // weekday 9 dropped, day 0 dropped, everything gone → "on schedule"
        #expect(BackgroundItemExplainer.calendarPart(
            [LaunchdCalendarInterval(minute: -1, hour: 99, day: 0, weekday: 9)]
        ) == "on schedule")
    }

    @Test("calendarPart narrates weekday+day compounds as on-schedule (launchd ANDs fields)")
    func calendarPartCompoundWeekdayDayIsOnSchedule() {
        let interval = LaunchdCalendarInterval(minute: 15, hour: 12, day: 1, weekday: 1)
        #expect(BackgroundItemExplainer.calendarPart([interval]) == "on schedule at 12:15")
    }

    @Test("calendarPart narrates the first VALID interval when a garbage one precedes it")
    func calendarPartSkipsGarbageToFirstNarratable() {
        let garbage = LaunchdCalendarInterval(minute: -1, hour: 99)
        let valid = LaunchdCalendarInterval(minute: 0, hour: 2)
        #expect(BackgroundItemExplainer.calendarPart([garbage, valid]) == "daily at 02:00")
    }

    @Test("Nonpositive StartInterval is not narrated")
    func nonpositiveStartIntervalDropped() {
        let plist = LaunchdPlist(
            label: "com.example.zero",
            program: "/usr/local/bin/zero",
            startInterval: 0
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(!result.contains("every"))
    }

    @Test("Suspicion outranks parentAppMissing in the impact phrase — no safety claim on a review item")
    func suspicionOutranksParentAppMissingImpact() {
        let plist = LaunchdPlist(label: "com.example.shady", program: "/tmp/shady")
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true,
            reasons: [.parentAppMissing, .suspiciousExecutablePath]
        )
        #expect(result.contains("review before trusting"))
        #expect(!result.contains("disabling should be safe"))
    }

    @Test("Fully populated line composes parts in the stable order")
    func fullLineComposition() {
        let plist = LaunchdPlist(
            label: "com.vendor.agent",
            program: "/Applications/Vendor.app/Contents/MacOS/agent",
            machServices: ["com.vendor.agent.xpc"],
            keepAlive: true,
            runAtLoad: true
        )
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Vendor.app/Contents/MacOS/agent",
            bundlePath: "/Applications/Vendor.app",
            bundleName: "Vendor",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Vendor Co"
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: identity,
            executableExists: true
        )
        #expect(result == "User LaunchAgent · signed by Vendor Co · ships with Vendor"
            + " · starts at login, kept running by launchd, starts on a Mach-service or socket request"
            + " · clients may fail to reach it if disabled")
    }

    @Test("Impact priority: sensitive category beats mach-service listener")
    func sensitiveCategoryBeatsMachImpact() {
        let plist = LaunchdPlist(
            label: "com.vpn.helper",
            program: "/Applications/VPN.app/Contents/MacOS/helper",
            machServices: ["com.vpn.helper.xpc"]
        )
        let identity = BinaryIdentity(
            binaryPath: "/Applications/VPN.app/Contents/MacOS/helper",
            vendor: .thirdPartyKnown,
            sensitiveCategories: [.vpn]
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("disabling may break VPN connectivity"))
        #expect(!result.contains("clients may fail to reach it"))
    }

    @Test("parentAppLikelyMissing reason surfaces the appears-uninstalled phrase")
    func parentAppLikelyMissingImpact() {
        let plist = LaunchdPlist(label: "com.example.maybe", program: "/usr/local/bin/maybe")
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true,
            reasons: [.parentAppLikelyMissing]
        )
        #expect(result.contains("its app appears uninstalled"))
    }

    @Test("calendarPart formats a weekly interval")
    func calendarPartWeekly() {
        let interval = LaunchdCalendarInterval(hour: 9, weekday: 1)
        #expect(BackgroundItemExplainer.calendarPart([interval]) == "weekly on Monday at 09:00")
    }

    @Test("calendarPart formats an hourly, minute-only interval without a leading '00:'")
    func calendarPartHourly() {
        let interval = LaunchdCalendarInterval(minute: 30)
        #expect(BackgroundItemExplainer.calendarPart([interval]) == "hourly at :30")
    }

    @Test("calendarPart falls back to 'on schedule' for an all-nil interval")
    func calendarPartFallback() {
        let interval = LaunchdCalendarInterval()
        #expect(BackgroundItemExplainer.calendarPart([interval]) == "on schedule")
    }

    @Test("calendarPart appends a count suffix for multiple intervals")
    func calendarPartMultiple() {
        let intervals = [
            LaunchdCalendarInterval(minute: 15, hour: 12, day: 1),
            LaunchdCalendarInterval(minute: 15, hour: 12, day: 15),
        ]
        let result = BackgroundItemExplainer.calendarPart(intervals)
        #expect(result?.contains("(+1 more)") == true)
    }

    @Test("KeepAlive trigger narrates as restart-on-exit")
    func keepAliveTrigger() {
        let plist = LaunchdPlist(label: "com.example.alive", program: "/usr/local/bin/alive", keepAlive: true)
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("kept running by launchd"))
    }

    @Test("RunAtLoad on a user launch agent narrates as starts-at-login")
    func runAtLoadUserAgent() {
        let plist = LaunchdPlist(label: "com.example.login", program: "/usr/local/bin/login", runAtLoad: true)
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(result.contains("starts at login"))
    }

    @Test("Sensitive VPN vendor surfaces the VPN disable-impact phrase")
    func vpnImpact() {
        let identity = BinaryIdentity(
            binaryPath: "/Applications/VPNClient.app/Contents/MacOS/vpn",
            bundleName: "VPN Client",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "VPN Co",
            sensitiveCategories: [.vpn]
        )
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: nil,
            identity: identity,
            executableExists: true
        )
        #expect(result.contains("disabling may break VPN connectivity"))
    }

    @Test("parentAppMissing reason surfaces the safe-to-disable impact phrase")
    func parentAppMissingImpact() {
        let plist = LaunchdPlist(label: "com.example.orphan", program: "/usr/local/bin/orphan")
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true,
            reasons: [.parentAppMissing]
        )
        #expect(result.contains("its app is gone — disabling should be safe"))
    }

    @Test("Suspicious reason surfaces the review-before-trusting impact phrase")
    func suspiciousImpact() {
        let plist = LaunchdPlist(label: "com.example.sus", program: "/tmp/sus")
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true,
            reasons: [.suspiciousExecutablePath]
        )
        #expect(result.contains("review before trusting"))
    }

    @Test("No impact signals produce no impact segment")
    func noImpactSignals() {
        let plist = LaunchdPlist(label: "com.example.plain", program: "/usr/local/bin/plain", runAtLoad: true)
        let result = explainer.explain(
            source: .userLaunchAgent,
            plist: plist,
            identity: nil,
            executableExists: true
        )
        #expect(!result.contains("disabling"))
        #expect(!result.contains("its app"))
        #expect(!result.contains("review before trusting"))
        #expect(!result.contains("clients may fail to reach it"))
        #expect(!result.contains("part of device management"))
    }

    @Test("Impact phrase is deterministic across repeated calls with two sensitive categories")
    func impactDeterminism() {
        let identity = BinaryIdentity(
            binaryPath: "/Applications/Backup.app/Contents/MacOS/backup",
            bundleName: "Backup Tool",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Backup Co",
            sensitiveCategories: [.backup, .security]
        )
        let first = explainer.explain(
            source: .userLaunchAgent,
            plist: nil,
            identity: identity,
            executableExists: true
        )
        let second = explainer.explain(
            source: .userLaunchAgent,
            plist: nil,
            identity: identity,
            executableExists: true
        )
        #expect(first == second)
        #expect(first.contains("disabling stops scheduled backups"))
    }
}
