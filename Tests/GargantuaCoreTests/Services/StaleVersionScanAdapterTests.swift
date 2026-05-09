import Foundation
import Testing
@testable import GargantuaCore

@Suite("StaleVersionScanAdapter")
struct StaleVersionScanAdapterTests {

    private static func makeFixture() throws -> FixtureTree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleVersionScanAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FixtureTree(root: root)
    }

    private static func family(
        id: String = "xcode-ios-device-support",
        productName: String = "Xcode iOS DeviceSupport",
        root: URL,
        keepLatest: Int = 1
    ) -> StaleVersionFamilyDefinition {
        StaleVersionFamilyDefinition(
            id: id,
            productName: productName,
            sourceName: "Xcode",
            roots: [root],
            style: .immediateChildren,
            keepLatest: keepLatest,
            tags: ["developer", "xcode", "stale_versions"]
        )
    }

    @Test("version identifiers compare dotted, build, Toolbox, and prefixed labels numerically")
    func versionIdentifierOrdering() {
        #expect(StaleVersionIdentifier("15.4 (21E219)") > StaleVersionIdentifier("14.5"))
        #expect(StaleVersionIdentifier("2024.2.1") > StaleVersionIdentifier("2023.3.9"))
        #expect(StaleVersionIdentifier("android-35") > StaleVersionIdentifier("android-34"))
        #expect(StaleVersionIdentifier("241.18034.62") > StaleVersionIdentifier("233.15026.9"))
    }

    @Test("keep-latest policy drops older Xcode DeviceSupport versions")
    func keepLatestDropsOlderVersions() async throws {
        let fixture = try Self.makeFixture()
        let root = try fixture.makeDir("Xcode/iOS DeviceSupport")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/16.0")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/17.0")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/18.0")

        let adapter = StaleVersionScanAdapter(
            families: [Self.family(root: root, keepLatest: 1)],
            categories: ["dev_artifacts"]
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.map(\.name) == [
            "Xcode iOS DeviceSupport — 17.0",
            "Xcode iOS DeviceSupport — 16.0",
        ])
        #expect(Set(results.map(\.safety)) == [.review])
        #expect(results.allSatisfy { $0.explanation.contains("Old alone is not safe evidence") })
        #expect(results.allSatisfy { !$0.isCommandAction })
    }

    @Test("pinned paths and current-version hints are kept before stale drops")
    func pinsAndCurrentVersionsAreKept() async throws {
        let fixture = try Self.makeFixture()
        let root = try fixture.makeDir("Xcode/iOS DeviceSupport")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/15.0")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/16.0")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/17.0")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/18.0")

        let family = Self.family(root: root, keepLatest: 1)
        let policy = StaleVersionRetentionPolicy(
            pinnedPaths: ["*/15.0"],
            currentVersions: [
                family.id: [StaleVersionIdentifier("16.0")],
            ]
        )
        let adapter = StaleVersionScanAdapter(
            families: [family],
            policy: policy,
            categories: ["dev_artifacts"]
        )

        let group = try #require(adapter.discoverGroups().first)
        let kept = group.decisions.filter { $0.action == .keep }
        let dropped = group.decisions.filter { $0.action == .drop }

        #expect(kept.map(\.candidate.version.rawValue).contains("18.0"))
        #expect(kept.map(\.candidate.version.rawValue).contains("16.0"))
        #expect(kept.map(\.candidate.version.rawValue).contains("15.0"))
        #expect(dropped.map(\.candidate.version.rawValue) == ["17.0"])
        #expect(kept.contains { $0.rationale.contains("pinned") })
        #expect(kept.contains { $0.rationale.contains("current or active") })
    }

    @Test("JetBrains Toolbox app channels group by product and keep recent fallback")
    func jetBrainsToolboxDiscovery() async throws {
        let fixture = try Self.makeFixture()
        let root = try fixture.makeDir("JetBrains/Toolbox/apps")
        try fixture.makeVersion("JetBrains/Toolbox/apps/IDEA-U/ch-0/233.15026.9")
        try fixture.makeVersion("JetBrains/Toolbox/apps/IDEA-U/ch-0/241.18034.62")
        try fixture.makeVersion("JetBrains/Toolbox/apps/IDEA-U/ch-0/242.20224.419")

        let family = StaleVersionFamilyDefinition(
            id: "jetbrains-toolbox",
            productName: "JetBrains Toolbox",
            sourceName: "JetBrains Toolbox",
            roots: [root],
            style: .jetBrainsToolboxApps,
            keepLatest: 2,
            tags: ["developer", "jetbrains", "stale_versions"]
        )
        let adapter = StaleVersionScanAdapter(
            families: [family],
            categories: ["dev_artifacts"]
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.name == "JetBrains IDEA U ch-0 — 233.15026.9")
        #expect(results.first?.source.name == "JetBrains Toolbox")
        #expect(results.first?.tags.contains("stale_versions") == true)
    }

    @Test("profile category gate excludes stale-version adapter outside developer scans")
    func categoryGateExcludesNonDeveloperProfiles() async throws {
        let fixture = try Self.makeFixture()
        let root = try fixture.makeDir("Xcode/iOS DeviceSupport")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/16.0")
        try fixture.makeVersion("Xcode/iOS DeviceSupport/17.0")

        let adapter = StaleVersionScanAdapter(
            families: [Self.family(root: root, keepLatest: 1)],
            categories: Set(CleanupProfile.light.categories)
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.isEmpty)
    }

    private final class FixtureTree {
        let root: URL

        init(root: URL) {
            self.root = root
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func makeDir(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func makeVersion(_ relative: String) throws -> URL {
            let url = try makeDir(relative)
            let marker = url.appendingPathComponent("payload.bin")
            try Data(repeating: 0x1, count: 128).write(to: marker)
            return url
        }
    }
}
