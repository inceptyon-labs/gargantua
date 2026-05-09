import Foundation
import Testing
@testable import GargantuaCore

private struct LaunchdRoots {
    let root: URL
    let userAgents: URL
    let systemAgents: URL
    let systemDaemons: URL
    let startupItems: URL
}

@Suite("LaunchdItemIndex")
struct LaunchdItemIndexTests {

    /// Build a temp directory tree mirroring the four launchd source roots,
    /// and write fixture plists into the requested domains.
    ///
    /// Caller is responsible for cleaning up `root`.
    private func makeTempRoots() throws -> LaunchdRoots {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchdItemIndexTests-\(UUID().uuidString)", isDirectory: true)
        let userAgents = root.appendingPathComponent("user/Library/LaunchAgents", isDirectory: true)
        let systemAgents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let systemDaemons = root.appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
        let startupItems = root.appendingPathComponent("Library/StartupItems", isDirectory: true)
        for dir in [userAgents, systemAgents, systemDaemons, startupItems] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return LaunchdRoots(
            root: root,
            userAgents: userAgents,
            systemAgents: systemAgents,
            systemDaemons: systemDaemons,
            startupItems: startupItems,
        )
    }

    private func writePlist(label: String, to dir: URL, named filename: String? = nil) throws {
        let dict: [String: Any] = [
            "Label": label,
            "Program": "/usr/local/bin/\(label.split(separator: ".").last ?? "")",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        let url = dir.appendingPathComponent(filename ?? "\(label).plist")
        try data.write(to: url)
    }

    private func makeIndex(roots: LaunchdRoots) -> DefaultLaunchdItemIndex {
        DefaultLaunchdItemIndex(
            userAgentsURL: roots.userAgents,
            systemAgentsURL: roots.systemAgents,
            systemDaemonsURL: roots.systemDaemons,
            startupItemsURL: roots.startupItems
        )
    }

    @Test("Enumerates plists across all four domains")
    func enumerateAllDomains() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        try writePlist(label: "com.user.agent", to: roots.userAgents)
        try writePlist(label: "com.system.agent", to: roots.systemAgents)
        try writePlist(label: "com.system.daemon", to: roots.systemDaemons)
        try writePlist(label: "com.startup.item", to: roots.startupItems)

        let items = makeIndex(roots: roots).enumerate()
        let labels = items.compactMap { $0.plist?.label }.sorted()
        #expect(labels == [
            "com.startup.item",
            "com.system.agent",
            "com.system.daemon",
            "com.user.agent",
        ])

        // Domain assignment must be correct
        let domains = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, LaunchdDomain)? in
                guard let label = item.plist?.label else { return nil }
                return (label, item.domain)
            }
        )
        #expect(domains["com.user.agent"] == .userAgent)
        #expect(domains["com.system.agent"] == .systemAgent)
        #expect(domains["com.system.daemon"] == .systemDaemon)
        #expect(domains["com.startup.item"] == .startupItem)
    }

    @Test("Same Label in user and system domains is preserved as two distinct items")
    func sameLabelAcrossDomains() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        // Same Label, different domains — these are different launchd entities
        try writePlist(label: "com.example.dual", to: roots.userAgents, named: "user.plist")
        try writePlist(label: "com.example.dual", to: roots.systemDaemons, named: "system.plist")

        let items = makeIndex(roots: roots).enumerate()
        let dualItems = items.filter { $0.plist?.label == "com.example.dual" }
        #expect(dualItems.count == 2)
        let domains = Set(dualItems.map { $0.domain })
        #expect(domains == [.userAgent, .systemDaemon])
    }

    @Test("Missing source directories are skipped gracefully")
    func missingDirectoriesAreSkipped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchdItemIndexTests-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Only create one of the four roots
        let userAgents = root.appendingPathComponent("user/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: userAgents, withIntermediateDirectories: true)
        try writePlist(label: "com.only.user", to: userAgents)

        let index = DefaultLaunchdItemIndex(
            userAgentsURL: userAgents,
            systemAgentsURL: root.appendingPathComponent("nope-1"),
            systemDaemonsURL: root.appendingPathComponent("nope-2"),
            startupItemsURL: root.appendingPathComponent("nope-3")
        )

        let items = index.enumerate()
        #expect(items.count == 1)
        #expect(items.first?.plist?.label == "com.only.user")
    }

    @Test("Unparseable plist surfaces parseError instead of being dropped")
    func unparseablePlistSurfacesError() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        // Write garbage that is neither XML nor binary plist
        let garbageURL = roots.userAgents.appendingPathComponent("com.broken.plist")
        try Data("not a plist".utf8).write(to: garbageURL)

        try writePlist(label: "com.good.agent", to: roots.userAgents)

        let items = makeIndex(roots: roots).enumerate()
        #expect(items.count == 2)
        let broken = items.first { $0.plist == nil }
        #expect(broken != nil)
        #expect(broken?.parseError != nil)
        #expect(broken?.plistPath.contains("com.broken.plist") == true)
    }

    @Test("Plist missing Label parses as parseError")
    func missingLabelSurfacesError() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        let url = roots.userAgents.appendingPathComponent("nolabel.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Program": "/usr/bin/foo"],
            format: .xml,
            options: 0
        )
        try data.write(to: url)

        let items = makeIndex(roots: roots).enumerate()
        #expect(items.count == 1)
        #expect(items.first?.plist == nil)
        #expect(items.first?.parseError != nil)
    }

    @Test("StartupItems directory descends one level for the per-item plist")
    func startupItemsDescendsOneLevel() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        let itemDir = roots.startupItems.appendingPathComponent("LegacyHelper", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        try writePlist(label: "com.legacy.helper", to: itemDir, named: "StartupParameters.plist")

        let items = makeIndex(roots: roots).enumerate()
        #expect(items.count == 1)
        #expect(items.first?.plist?.label == "com.legacy.helper")
        #expect(items.first?.domain == .startupItem)
    }

    @Test("Non-plist files in source dirs are ignored")
    func nonPlistFilesIgnored() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        try writePlist(label: "com.real.thing", to: roots.userAgents)
        try Data("readme".utf8).write(to: roots.userAgents.appendingPathComponent("README"))
        try Data("notes".utf8).write(to: roots.userAgents.appendingPathComponent("notes.txt"))

        let items = makeIndex(roots: roots).enumerate()
        #expect(items.count == 1)
    }

    @Test("Plist files are returned in deterministic sorted order")
    func deterministicOrder() throws {
        let roots = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: roots.root) }

        try writePlist(label: "com.zeta.thing", to: roots.userAgents)
        try writePlist(label: "com.alpha.thing", to: roots.userAgents)
        try writePlist(label: "com.mu.thing", to: roots.userAgents)

        let items = makeIndex(roots: roots).enumerate()
        let userItems = items.filter { $0.domain == .userAgent }
        let labels = userItems.compactMap { $0.plist?.label }
        #expect(labels == ["com.alpha.thing", "com.mu.thing", "com.zeta.thing"])
    }
}
