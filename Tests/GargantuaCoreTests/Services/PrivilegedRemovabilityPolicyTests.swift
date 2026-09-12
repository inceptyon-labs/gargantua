import Foundation
import Testing
@testable import GargantuaCore

@Suite("PrivilegedRemovabilityPolicy")
struct PrivilegedRemovabilityPolicyTests {
    let policy = PrivilegedRemovabilityPolicy.shared

    // MARK: - Uninstaller scope (pre-existing behavior preserved)

    @Test("App bundles, launch daemon plists, and helper tools stay allowed")
    func uninstallerScopePreserved() {
        #expect(policy.allows(path: "/Applications/Foo.app", isDirectory: true))
        #expect(policy.allows(path: "/Library/LaunchDaemons/com.x.plist", isDirectory: false))
        #expect(policy.allows(path: "/Library/PrivilegedHelperTools/com.x", isDirectory: false))
        // Wrong shape is rejected.
        #expect(!policy.allows(path: "/Applications/Foo.app", isDirectory: false))
        #expect(!policy.allows(path: "/Applications/Sub/Foo.app", isDirectory: true))
        #expect(!policy.allows(path: "/Library/LaunchDaemons/com.x.txt", isDirectory: false))
    }

    // MARK: - Tier-1 system roots are removable

    @Test("Tier-1 system roots and their descendants are allowed")
    func tier1RootsAllowed() {
        let tier1Samples = [
            "/private/var/db/powerlog/Library/foo.PLSQL",
            "/private/var/db/DiagnosticPipeline/bar",
            "/private/var/db/reportmemoryexception/MemoryLimitViolations/x.log",
            "/Library/Caches/com.example/blob",
            "/Library/Logs/DiagnosticReports/crash.ips",
            "/Library/Logs/Adobe/x.log",
            "/Library/Updates/031-1234/payload",
            "/Library/Apple/usr/share/rosetta/rosetta_update_bundle/x",
            "/macOS Install Data/x",
            "/private/tmp/x",
            "/private/var/tmp/x",
            "/private/var/log/powermanagement/2026.05.24.asl",
        ]
        for path in tier1Samples {
            #expect(policy.allows(path: path, isDirectory: false), "expected allowed: \(path)")
        }
        // The root itself is allowed, not only descendants.
        #expect(policy.allows(path: "/private/var/db/powerlog", isDirectory: true))
    }

    @Test("Canonical /var form matches the /private/var roots (firmlink regression)")
    func firmlinkCanonicalizationAllowed() {
        // macOS standardizedFileURL rewrites /private/var/... -> /var/..., which
        // is what the helper actually validates. Both forms must be allowed or
        // tier-1 silently fails (the field bug).
        #expect(policy.allows(path: "/var/db/powerlog/Library", isDirectory: true))
        #expect(policy.allows(path: "/var/db/powerlog/Library/foo.PLSQL", isDirectory: false))
        #expect(policy.allows(path: "/var/db/reportmemoryexception/MemoryLimitViolations/x", isDirectory: false))
        #expect(policy.allows(path: "/tmp/x", isDirectory: false))
        #expect(policy.allows(path: "/private/tmp/x", isDirectory: false))
        // The canonical /var form of the held-back diagnostics store is still rejected.
        #expect(!policy.allows(path: "/var/db/diagnostics/logd.1.log", isDirectory: false))
    }

    @Test("code_sign_clone files under var/folders are allowed, but nothing else there")
    func varFoldersSuffixCarveOut() {
        #expect(policy.allows(
            path: "/private/var/folders/ab/cd/X/thing.code_sign_clone",
            isDirectory: false
        ))
        // The active per-session temp tree itself is never wholesale-removable.
        #expect(!policy.allows(path: "/private/var/folders/ab/cd/C/somecache", isDirectory: false))
        #expect(!policy.allows(path: "/private/var/folders/ab/cd", isDirectory: true))
    }

    // MARK: - Tier-2 holdbacks must NOT be removable

    @Test("The live diagnostics store is held back — never allowed")
    func liveDiagnosticsStoreHeldBack() {
        // /private/var/db/diagnostics is the live unified-logging store (logd
        // writes it continuously). It must never be allowlisted.
        #expect(!policy.allows(path: "/private/var/db/diagnostics", isDirectory: true))
        #expect(!policy.allows(path: "/private/var/db/diagnostics/logd.1.log", isDirectory: false))
        #expect(!policy.allows(path: "/private/var/db/diagnostics/Persist/x.tracev3", isDirectory: false))
    }

    // MARK: - Everything else is rejected

    @Test("Arbitrary system and user paths are rejected")
    func arbitraryPathsRejected() {
        for path in [
            "/System/Library/Caches/x",
            "/usr/bin/x",
            "/etc/hosts",
            "/Users/someone/Documents/x",
            "/private/var/db/x",
            "/Library/x",
            "/",
        ] {
            #expect(!policy.allows(path: path, isDirectory: false), "expected rejected: \(path)")
        }
        // Prefix-trap guard: /Library/CachesEvil must not match /Library/Caches.
        #expect(!policy.allows(path: "/Library/CachesEvil/x", isDirectory: false))
    }

    // MARK: - Hard-link guard (H1 local-privilege-escalation defense)

    @Test("A regular file with more than one hard link is flagged; a single-link file is not")
    func multiplyLinkedRegularFileFlagged() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gtua-hlguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A plain regenerable file — the legitimate cleanup case.
        let single = dir.appendingPathComponent("cache.bin")
        try Data("x".utf8).write(to: single)
        #expect(!policy.isMultiplyLinkedRegularFile(path: single.path))

        // Add a second hard link (the attack primitive: a second name for the
        // same inode). Both names now report st_nlink == 2.
        let secondName = dir.appendingPathComponent("planted")
        #expect(link(single.path, secondName.path) == 0)
        #expect(policy.isMultiplyLinkedRegularFile(path: single.path))
        #expect(policy.isMultiplyLinkedRegularFile(path: secondName.path))

        // Directories carry st_nlink >= 2 by nature and must NOT be flagged.
        #expect(!policy.isMultiplyLinkedRegularFile(path: dir.path))

        // A symlink is inspected as the link (lstat), not its multiply-linked
        // target, so it is not flagged as a multiply-linked regular file.
        let symlink = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: single)
        #expect(!policy.isMultiplyLinkedRegularFile(path: symlink.path))

        // A path that does not exist reads as false (existence is a separate guard).
        #expect(!policy.isMultiplyLinkedRegularFile(path: dir.appendingPathComponent("gone").path))
    }
}
