import Foundation
import Testing
@testable import GargantuaCore

extension AuditWriterTests {
    @Test("the default sidecar lives in Application Support, out of system_logs' reach")
    func defaultSidecarIsOutsideLogsDirectory() {
        let writer = AuditWriter()
        let lockPath = writer.lockFile.path

        #expect(lockPath.hasSuffix("Library/Application Support/Gargantua/audit.lock"))
        // The whole point of the move: `system_logs` sweeps ~/Library/Logs and
        // only an upstream-owned exclusion spares our subdirectory.
        #expect(!lockPath.contains("/Library/Logs/"))
    }

    @Test("the default log file is unchanged by the sidecar move")
    func defaultLogFileUnchanged() {
        #expect(AuditWriter().logFile.path.hasSuffix("Library/Logs/Gargantua/audit.json"))
    }

    @Test("an explicit log directory keeps the sidecar beside the log")
    func explicitLogDirectoryKeepsSidecarAlongside() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        #expect(writer.lockFile == dir.appendingPathComponent("audit.lock"))
    }

    @Test("an explicit lock directory overrides both defaults")
    func explicitLockDirectoryWins() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir) }

        let writer = AuditWriter(logDirectory: logDir, lockDirectory: lockDir)
        #expect(writer.lockFile == lockDir.appendingPathComponent("audit.lock"))
        #expect(writer.logFile == logDir.appendingPathComponent("audit.json"))
    }

    @Test("the sidecar still excludes a peer when it lives outside the log directory")
    func sidecarExcludesPeerAcrossDirectories() throws {
        let logDir = try makeTempDir()
        let lockDir = try makeTempDir()
        defer { cleanup(logDir); cleanup(lockDir) }

        let writer = AuditWriter(logDirectory: logDir, lockDirectory: lockDir, lockTimeout: 0.2)
        // Materialize both the log and the sidecar before contending.
        try writer.write(makeEntry(path: "/seed"))
        #expect(FileManager.default.fileExists(atPath: lockDir.appendingPathComponent("audit.lock").path))

        let held = Darwin.open(lockDir.appendingPathComponent("audit.lock").path, O_WRONLY | O_CREAT, 0o644)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)
        defer { _ = flock(held, LOCK_UN); Darwin.close(held) }

        // With the peer holding the sidecar, the append must give up rather
        // than write unsynchronised.
        #expect(throws: (any Error).self) {
            try writer.write(makeEntry(path: "/blocked"))
        }
    }

    @Test("acquiring the lock creates a missing sidecar directory")
    func createsMissingLockDirectory() throws {
        let logDir = try makeTempDir()
        defer { cleanup(logDir) }
        let lockDir = logDir.appendingPathComponent("nested/not-yet-created")

        let writer = AuditWriter(logDirectory: logDir, lockDirectory: lockDir)
        try writer.write(makeEntry(path: "/creates-dir"))

        #expect(FileManager.default.fileExists(atPath: lockDir.appendingPathComponent("audit.lock").path))
    }
}
