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
        do {
            try writer.write(makeEntry(path: "/blocked"))
            Issue.record("expected write(_:) to throw when the legacy sidecar is held")
        } catch let AuditWriteError.lockFailed(code) {
            #expect(code == EWOULDBLOCK)
        } catch {
            Issue.record("expected .lockFailed(code: EWOULDBLOCK), got \(error)")
        }
        #expect(try writer.readEntries().count == 1)
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

    @Test("a legacy sidecar hardlinked to the current one is detected by inode, not by path")
    func hardlinkedLegacySidecarDoesNotDeadlock() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        let legacyDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir); cleanup(legacyDir) }

        // One inode, two paths — nothing about the spelling reveals the overlap.
        let current = lockDir.appendingPathComponent("audit.lock")
        let legacy = legacyDir.appendingPathComponent("audit.lock")
        #expect(FileManager.default.createFile(atPath: current.path, contents: nil))
        try FileManager.default.linkItem(at: current, to: legacy)

        let writer = AuditWriter(
            logDirectory: logDir,
            lockDirectory: lockDir,
            legacyLockDirectory: legacyDir,
            lockTimeout: 0.5
        )
        // init compares spelling, so it cannot rule this one out.
        #expect(writer.legacyLockFile != nil)

        try writer.write(makeEntry(path: "/hardlinked"))
        #expect(try writer.readEntries().count == 1)
    }

    @Test("dual-locking shares one deadline rather than giving each sidecar its own")
    func dualLockSharesOneDeadline() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        let legacyDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir); cleanup(legacyDir) }

        let writer = AuditWriter(
            logDirectory: logDir,
            lockDirectory: lockDir,
            legacyLockDirectory: legacyDir,
            lockTimeout: 1.0
        )
        try writer.write(makeEntry(path: "/seed"))

        // A peer holds both sidecars, then hands back only the legacy one
        // half-way through the budget. The current sidecar is never released,
        // so the acquisition still fails — what's under test is WHEN.
        let legacyHeld = Darwin.open(legacyDir.appendingPathComponent("audit.lock").path,
                                     O_RDONLY | O_CREAT, 0o644)
        #expect(legacyHeld >= 0)
        #expect(flock(legacyHeld, LOCK_EX) == 0)
        let currentHeld = Darwin.open(lockDir.appendingPathComponent("audit.lock").path,
                                      O_RDONLY | O_CREAT, 0o644)
        #expect(currentHeld >= 0)
        #expect(flock(currentHeld, LOCK_EX) == 0)
        defer { _ = flock(currentHeld, LOCK_UN); Darwin.close(currentHeld) }

        let releaser = Thread {
            Thread.sleep(forTimeInterval: 0.5)
            _ = flock(legacyHeld, LOCK_UN)
            Darwin.close(legacyHeld)
        }
        releaser.start()

        let start = Date()
        #expect(throws: (any Error).self) {
            try writer.write(makeEntry(path: "/blocked"))
        }
        let elapsed = Date().timeIntervalSince(start)

        // Shared budget: 0.5s waiting for the legacy sidecar, then the ~0.5s
        // that remains on the same deadline. A per-sidecar budget would restart
        // the clock and land near 1.5s.
        #expect(elapsed >= 0.9, "gave up before the shared budget was spent: \(elapsed)s")
        #expect(elapsed < 1.3, "the clock restarted — each sidecar got its own budget: \(elapsed)s")
    }

    @Test("the legacy sidecar is acquired before the current one")
    func legacySidecarIsAcquiredFirst() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        let legacyDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir); cleanup(legacyDir) }

        // Materialize and hold ONLY the legacy sidecar; leave the current one
        // absent so its creation is observable.
        let legacyLock = legacyDir.appendingPathComponent("audit.lock")
        let held = Darwin.open(legacyLock.path, O_RDONLY | O_CREAT, 0o644)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)
        defer { _ = flock(held, LOCK_UN); Darwin.close(held) }

        let writer = AuditWriter(
            logDirectory: logDir,
            lockDirectory: lockDir,
            legacyLockDirectory: legacyDir,
            lockTimeout: 0.2
        )
        #expect(throws: (any Error).self) {
            try writer.write(makeEntry(path: "/ordered"))
        }

        // acquireDescriptor creates the sidecar it opens. The current sidecar
        // can only still be absent if the legacy acquisition ran first and
        // aborted the whole attempt before the current one was ever opened.
        #expect(!FileManager.default.fileExists(atPath: lockDir.appendingPathComponent("audit.lock").path))
    }
}
