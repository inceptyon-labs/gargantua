import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

@Suite("SpotlightOrphanRuleScanner")
struct SpotlightOrphanRuleScannerTests {
    private struct FakeReader: SpotlightRulesReading {
        let ids: [String]
        func enabledRuleIdentifiers() -> [String] { ids }
    }

    private struct FakeResolver: InstalledAppResolving {
        let installed: Set<String>
        func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
    }

    private final class CapturingWriter: SpotlightRulesWriting, @unchecked Sendable {
        private(set) var kept: [String]?
        func write(keptIdentifiers: [String]) throws { kept = keptIdentifiers }
    }

    private static let mixedRules = [
        "System.Applications",
        "com.apple.Safari",
        "com.figma.Desktop", // orphan (not installed)
        "com.docker.docker", // installed → kept
        "com.gone.app", // orphan (not installed)
        "/Applications/Weird.app", // path-like → ignored
        "single", // not reverse-DNS → ignored
    ]

    @Test("only uninstalled third-party reverse-DNS rules are orphans")
    func detectsOrphans() {
        let scanner = SpotlightOrphanRuleScanner(
            reader: FakeReader(ids: Self.mixedRules),
            resolver: FakeResolver(installed: ["com.docker.docker"])
        )

        let orphans = scanner.findOrphans().map(\.identifier)
        #expect(orphans == ["com.figma.Desktop", "com.gone.app"])
    }

    @Test("system, apple, installed, path-like and non-DNS rules are never orphans")
    func preservesProtectedRules() {
        let scanner = SpotlightOrphanRuleScanner(
            reader: FakeReader(ids: Self.mixedRules),
            resolver: FakeResolver(installed: ["com.docker.docker"])
        )
        let orphans = Set(scanner.findOrphans().map(\.identifier))

        for kept in ["System.Applications", "com.apple.Safari", "com.docker.docker", "/Applications/Weird.app", "single"] {
            #expect(!orphans.contains(kept))
        }
    }

    @Test("dry run computes orphans but never writes")
    func dryRunDoesNotWrite() async throws {
        let writer = CapturingWriter()
        let scanner = SpotlightOrphanRuleScanner(
            reader: FakeReader(ids: Self.mixedRules),
            writer: writer,
            resolver: FakeResolver(installed: ["com.docker.docker"]),
            authorizeDestructive: { .unchecked(.spotlightOrphanRules) }
        )

        let outcome = try await scanner.prune(dryRun: true)
        #expect(outcome.didWrite == false)
        #expect(outcome.removed.map(\.identifier) == ["com.figma.Desktop", "com.gone.app"])
        #expect(writer.kept == nil)
    }

    @Test("prune writes the retained set, dropping only orphans")
    func pruneWritesFilteredSet() async throws {
        let writer = CapturingWriter()
        let scanner = SpotlightOrphanRuleScanner(
            reader: FakeReader(ids: Self.mixedRules),
            writer: writer,
            resolver: FakeResolver(installed: ["com.docker.docker"]),
            authorizeDestructive: { .unchecked(.spotlightOrphanRules) }
        )

        let outcome = try await scanner.prune()
        #expect(outcome.didWrite)
        let kept = try #require(writer.kept)
        #expect(!kept.contains("com.figma.Desktop"))
        #expect(!kept.contains("com.gone.app"))
        #expect(kept.contains("System.Applications"))
        #expect(kept.contains("com.apple.Safari"))
        #expect(kept.contains("com.docker.docker"))
    }

    @Test("a blocked destructive gate prevents any write")
    func blockedGateThrows() async {
        let writer = CapturingWriter()
        let scanner = SpotlightOrphanRuleScanner(
            reader: FakeReader(ids: Self.mixedRules),
            writer: writer,
            resolver: FakeResolver(installed: []),
            authorizeDestructive: { nil }
        )

        await #expect(throws: SpotlightOrphanRuleScanner.PruneError.destructiveActionBlocked) {
            try await scanner.prune()
        }
        #expect(writer.kept == nil)
    }

    @Test("no orphans means no write")
    func noOrphansNoWrite() async throws {
        let writer = CapturingWriter()
        let scanner = SpotlightOrphanRuleScanner(
            reader: FakeReader(ids: ["System.Applications", "com.apple.Safari", "com.docker.docker"]),
            writer: writer,
            resolver: FakeResolver(installed: ["com.docker.docker"]),
            authorizeDestructive: { .unchecked(.spotlightOrphanRules) }
        )

        let outcome = try await scanner.prune()
        #expect(outcome.didWrite == false)
        #expect(outcome.removed.isEmpty)
        #expect(writer.kept == nil)
    }
}
