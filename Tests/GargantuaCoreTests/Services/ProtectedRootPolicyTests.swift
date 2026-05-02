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

    @Test("user store adds and removes custom protected roots")
    func userStoreRoundTrip() throws {
        let suite = "gargantua-protected-root-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
