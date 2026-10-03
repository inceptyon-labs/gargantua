import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProtectedRootPolicy")
struct ProtectedRootPolicyTests {
    @Test("parser loads protected roots from YAML")
    func parserLoadsProtectedRoots() throws {
        let yaml = """
        version: 1
        protected_roots:
          - path: "~/Library"
            reason: "User Library root"
          - path: "/private/var/folders/*/*/C"
            reason: "macOS-managed cache bucket root"
        """

        let entries = try ProtectedRootPolicyParser().parse(yaml: yaml)

        #expect(entries.count == 2)
        #expect(entries[0].path == "~/Library")
        #expect(entries[0].reason == "User Library root")
        #expect(entries[0].source == .bundled)
    }

    @Test("bundled policy resource loads and includes Library roots")
    func bundledPolicyLoads() throws {
        let policy = try ProtectedRootPolicyLoader().loadBundled()
        let paths = Set(policy.entries.map(\.path))

        #expect(paths.contains("~/Library"))
        #expect(paths.contains("/Library"))
        #expect(paths.contains("/System/Library"))
        #expect(paths.contains("/private/var/folders/*/*/C"))
    }

    @Test("policy matches exact roots using supplied home directory")
    func policyMatchesExactRoots() {
        let home = URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true)
        let policy = ProtectedRootPolicy(entries: [
            ProtectedRootEntry(path: "${HOME}/Library", reason: "User Library root"),
            ProtectedRootEntry(path: "/System/Volumes/Data${HOME}/Library", reason: "Data-volume Library root"),
        ])

        #expect(policy.protectionReason(
            for: home.appendingPathComponent("Library", isDirectory: true),
            homeDirectory: home
        ) == "User Library root")
        #expect(policy.protectionReason(
            for: URL(fileURLWithPath: "/System/Volumes/Data/Users/gargantua-test/Library", isDirectory: true),
            homeDirectory: home
        ) == "Data-volume Library root")
        #expect(policy.protectionReason(
            for: home.appendingPathComponent("Library/Caches/com.example.app", isDirectory: true),
            homeDirectory: home
        ) == nil)
    }

    @Test("policy matches glob roots by full path segment count")
    func policyMatchesGlobRoots() {
        let policy = ProtectedRootPolicy(entries: [
            ProtectedRootEntry(path: "/private/var/folders/*/*/C", reason: "cache bucket"),
        ])
        let home = URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true)

        #expect(policy.protectionReason(
            for: URL(fileURLWithPath: "/private/var/folders/tr/bucket/C", isDirectory: true),
            homeDirectory: home
        ) == "cache bucket")
        #expect(policy.protectionReason(
            for: URL(fileURLWithPath: "/private/var/folders/tr/bucket/C/com.example.child", isDirectory: true),
            homeDirectory: home
        ) == nil)
    }

    @Test("case-twisted spelling of a protected root is still protected on case-insensitive volumes")
    func caseTwistedSpellingIsStillProtected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protected-root-case-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // "library" names the same on-disk directory as "Library" only on a
        // case-insensitive volume (the APFS default). On a case-sensitive
        // volume there is nothing to bypass, so the scenario doesn't apply.
        let twisted = base.appendingPathComponent("library", isDirectory: true)
        guard FileManager.default.fileExists(atPath: twisted.path) else { return }

        let home = URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true)
        let policy = ProtectedRootPolicy(entries: [
            ProtectedRootEntry(path: real.path, reason: "User Library root"),
        ])

        #expect(policy.protectionReason(for: twisted, homeDirectory: home) == "User Library root")
        // And the reverse: an entry authored with the wrong case still
        // protects the real directory.
        let twistedEntryPolicy = ProtectedRootPolicy(entries: [
            ProtectedRootEntry(path: twisted.path, reason: "User Library root"),
        ])
        #expect(twistedEntryPolicy.protectionReason(for: real, homeDirectory: home) == "User Library root")
        // A sibling that genuinely doesn't exist under the root stays cleanable.
        let unrelated = base.appendingPathComponent("Caches", isDirectory: true)
        #expect(policy.protectionReason(for: unrelated, homeDirectory: home) == nil)
    }

    @Test("canonicalDiskCasePath resolves a twisted spelling to the real on-disk case")
    func canonicalDiskCasePathResolvesRealCase() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-case-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // The real directory canonicalizes to itself (real case preserved).
        let canonicalReal = try #require(ProtectedRootPolicy.canonicalDiskCasePath(real.path))
        #expect(URL(fileURLWithPath: canonicalReal).lastPathComponent == "Library")

        // A case-twisted spelling that names the same directory (only possible
        // on a case-insensitive volume, the APFS default) canonicalizes to the
        // real case — this is why the fold screen confirms as a match. On a
        // case-sensitive volume the twisted name doesn't exist, the deepest
        // existing ancestor is `base`, and the nonexistent leaf is appended
        // verbatim ("library"), which does NOT collide with "Library" — which
        // is exactly why a genuinely distinct dir is never over-matched.
        let twisted = base.appendingPathComponent("library", isDirectory: true)
        let canonicalTwisted = try #require(ProtectedRootPolicy.canonicalDiskCasePath(twisted.path))
        if FileManager.default.fileExists(atPath: twisted.path) {
            #expect(canonicalTwisted == canonicalReal)
        } else {
            #expect(URL(fileURLWithPath: canonicalTwisted).lastPathComponent == "library")
            #expect(canonicalTwisted != canonicalReal)
        }
    }

    @Test("canonicalDiskCasePath keeps nonexistent trailing components verbatim")
    func canonicalDiskCasePathKeepsMissingComponents() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let missing = base.appendingPathComponent("Nope/Deeper", isDirectory: true)
        let canonical = try #require(ProtectedRootPolicy.canonicalDiskCasePath(missing.path))
        #expect(canonical.hasSuffix("/Nope/Deeper"))

        // Even a path whose every named component is missing still rebuilds
        // from the always-canonicalizable root, so the leaf is preserved.
        let leaf = "ghost-\(UUID().uuidString)"
        let underRoot = try #require(ProtectedRootPolicy.canonicalDiskCasePath("/\(leaf)/x"))
        #expect(underRoot.hasSuffix("/\(leaf)/x"))
    }

    @Test("user store adds and removes custom protected roots")
    func userStoreRoundTrip() throws {
        let suite = "gargantua-protected-root-store-\(UUID().uuidString)"
        let defaults = TestDefaults.suite(suite)
        defaults.removePersistentDomain(forName: suite)
        let store = ProtectedRootUserStore(defaults: defaults)

        #expect(store.add(path: "~/Important"))
        #expect(!store.add(path: "~/Important"))
        #expect(store.loadEntries() == [
            ProtectedRootEntry(path: "~/Important", reason: "User-added protected root", source: .user)
        ])

        store.remove(path: "~/Important")
        #expect(store.loadEntries().isEmpty)
    }
}
