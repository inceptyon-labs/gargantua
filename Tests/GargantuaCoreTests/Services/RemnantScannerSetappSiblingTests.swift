import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantScanner Setapp sibling")
struct RemnantScannerSetappSiblingTests {
    private struct FakeResolver: InstalledAppResolving {
        let installed: Set<String>
        func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
    }

    private let setappApp = AppInfo(
        bundleID: "com.bjango.istatmenus-setapp",
        name: "iStat Menus",
        bundlePath: "/Applications/Setapp/iStat Menus.app"
    )

    private func daemonRule(_ fixture: FixtureTree) -> RemnantRule {
        RemnantRule(
            id: "generic_launch_daemons",
            name: "Launch daemons",
            category: .launchDaemons,
            pathTemplates: [
                fixture.root.appendingPathComponent("LaunchDaemons/{bundleID}.plist").path,
                fixture.root.appendingPathComponent("LaunchDaemons/{bundleID}.*.plist").path,
            ],
            confidence: 80,
            explanation: "System-wide daemons.",
            source: SourceAttribution(name: "{appName}")
        )
    }

    private func cacheRule(_ fixture: FixtureTree) -> RemnantRule {
        RemnantRule(
            id: "generic_caches",
            name: "Caches",
            category: .caches,
            pathTemplates: [fixture.root.appendingPathComponent("Caches/{bundleID}").path],
            confidence: 99,
            explanation: "Disposable cache data.",
            source: SourceAttribution(name: "{appName}")
        )
    }

    private func scanner(_ fixture: FixtureTree, installed: Set<String>) -> RemnantScanner {
        RemnantScanner(
            rules: [daemonRule(fixture), cacheRule(fixture)],
            scanRoots: [fixture.root],
            siblingAppResolver: FakeResolver(installed: installed)
        )
    }

    @Test("strips only a -setapp suffix")
    func siblingBundleID() {
        #expect(RemnantScanner.setappSiblingBundleID(for: "com.bjango.istatmenus-setapp") == "com.bjango.istatmenus")
        #expect(RemnantScanner.setappSiblingBundleID(for: "com.surteesstudios.Bartender-Setapp")
            == "com.surteesstudios.Bartender")
        #expect(RemnantScanner.setappSiblingBundleID(for: "com.bjango.istatmenus") == nil)
        #expect(RemnantScanner.setappSiblingBundleID(for: "setapp-setapp") == nil)
    }

    @Test("a -setapp app also finds the direct build's leftovers, marked for review")
    func findsSiblingRemnants() throws {
        let fixture = try FixtureTree()
        let own = try fixture.makeFile("LaunchDaemons/com.bjango.istatmenus-setapp.helper.plist")
        let sibling = try fixture.makeFile("LaunchDaemons/com.bjango.istatmenus.installer.plist")
        let cache = try fixture.makeFile("Caches/com.bjango.istatmenus/cache.db").deletingLastPathComponent()

        let plan = scanner(fixture, installed: []).plan(for: setappApp, includeAppBundle: false)

        #expect(Set(plan.remnants.map(\.path)) == [own.path, sibling.path, cache.path])
        let item = try #require(plan.remnants.first { $0.path == sibling.path })
        #expect(item.tags.contains(RemnantScanner.setappSiblingTag))
        #expect(item.safety == .protected_)
        #expect(plan.remnants.first { $0.path == cache.path }?.safety == .review)
        #expect(item.appBundleID == "com.bjango.istatmenus-setapp")
        #expect(item.source.bundleID == "com.bjango.istatmenus")
        #expect(item.explanation.contains("non-Setapp build"))
        #expect(Set(plan.remnants.map(\.id)).count == plan.remnants.count)
    }

    @Test("an installed direct build keeps its files")
    func skipsInstalledSibling() throws {
        let fixture = try FixtureTree()
        try fixture.makeFile("LaunchDaemons/com.bjango.istatmenus.installer.plist")
        try fixture.makeFile("Caches/com.bjango.istatmenus/cache.db")

        let plan = scanner(fixture, installed: ["com.bjango.istatmenus"]).plan(for: setappApp, includeAppBundle: false)

        #expect(plan.remnants.isEmpty)
    }
}
