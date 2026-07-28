import Foundation
import Testing
@testable import GargantuaCore

extension AuditWriterTests {
    @Test("the default writer also holds the pre-relocation Logs sidecar")
    func defaultWriterDualLocksLegacySidecar() {
        #expect(AuditWriter().legacyLockFile?.path.hasSuffix("Library/Logs/Gargantua/audit.lock") == true)
    }

    @Test("an explicit production logDirectory still dual-locks the legacy sidecar")
    func explicitProductionLogDirectoryDualLocksLegacySidecar() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let writer = AuditWriter(logDirectory: home.appendingPathComponent("Library/Logs/Gargantua"))
        #expect(writer.legacyLockFile?.path.hasSuffix("Library/Logs/Gargantua/audit.lock") == true)
    }

    @Test("an explicit log directory never relocated, so there is no legacy sidecar")
    func explicitLogDirectoryHasNoLegacySidecar() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        #expect(AuditWriter(logDirectory: dir).legacyLockFile == nil)
    }

    @Test("an explicit lock directory never relocated, so there is no legacy sidecar")
    func explicitLockDirectoryHasNoLegacySidecar() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir) }
        #expect(AuditWriter(logDirectory: logDir, lockDirectory: lockDir).legacyLockFile == nil)
    }

    @Test("a peer holding only the legacy sidecar still blocks an append")
    func legacySidecarPeerBlocksAppend() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        let legacyDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir); cleanup(legacyDir) }

        // Stands in for a pre-upgrade GargantuaMCP: it knows only the old path.
        let writer = AuditWriter(
            logDirectory: logDir,
            lockDirectory: lockDir,
            legacyLockDirectory: legacyDir,
            lockTimeout: 0.2
        )
        try writer.write(makeEntry(path: "/seed"))

        let legacyLock = legacyDir.appendingPathComponent("audit.lock")
        #expect(FileManager.default.fileExists(atPath: legacyLock.path))

        let held = Darwin.open(legacyLock.path, O_WRONLY | O_CREAT, 0o644)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)
        defer { _ = flock(held, LOCK_UN); Darwin.close(held) }

        // Before the dual-lock the current build ignored this sidecar entirely
        // and would have appended straight through the peer.
        #expect(throws: (any Error).self) {
            try writer.write(makeEntry(path: "/blocked"))
        }
    }

    @Test("a legacy sidecar path coinciding with the current one does not self-deadlock")
    func coincidingLegacySidecarDoesNotDeadlock() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Both resolve to <dir>/audit.lock. acquireDescriptor is not reentrant,
        // so a second flock on the same file would spin until the timeout.
        let writer = AuditWriter(logDirectory: dir, legacyLockDirectory: dir, lockTimeout: 0.2)
        #expect(writer.legacyLockFile == nil)

        try writer.write(makeEntry(path: "/no-deadlock"))
        #expect(try writer.readEntries().count == 1)
    }

    @Test("back-to-back writes with a distinct legacy sidecar don't strand the lock")
    func dualLockIsReleasedBetweenWrites() throws {
        let logDir = try makeTempDir()
        let legacyDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(legacyDir) }

        let writer = AuditWriter(logDirectory: logDir, legacyLockDirectory: legacyDir, lockTimeout: 0.2)
        try writer.write(makeEntry(path: "/one"))
        try writer.write(makeEntry(path: "/two"))

        #expect(try writer.readEntries().count == 2)
    }
}
