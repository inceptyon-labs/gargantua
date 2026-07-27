import Foundation
import os
import Testing
@testable import GargantuaCore

extension AuditWriterTests {
    @Test("purgeEntries removes entries older than retention period")
    func purgeOldEntries() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()

        // Write an old entry (100 days ago)
        let oldEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-100 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/old", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(oldEntry)

        // Write a recent entry (5 days ago)
        let recentEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-5 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/recent", size: 200)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 200
        )
        try writer.write(recentEntry)

        let purged = try writer.purgeEntries(olderThanDays: 90, now: now)
        #expect(purged == 1)

        let remaining = try writer.readEntries()
        #expect(remaining.count == 1)
        #expect(remaining[0].files[0].path == "/recent")
    }

    @Test("purgeEntries with default 90-day retention")
    func purgeDefault90Days() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()

        // Write entry at 89 days (should be kept)
        let keepEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-89 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/keep", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(keepEntry)

        // Write entry at 91 days (should be purged)
        let purgeEntry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-91 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/purge", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(purgeEntry)

        let purged = try writer.purgeEntries(now: now)
        #expect(purged == 1)

        let remaining = try writer.readEntries()
        #expect(remaining.count == 1)
        #expect(remaining[0].files[0].path == "/keep")
    }

    @Test("purgeEntries returns 0 for nonexistent log")
    func purgeNonexistentLog() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir.appendingPathComponent("nope"))
        let purged = try writer.purgeEntries()
        #expect(purged == 0)
    }

    @Test("purgeEntries returns 0 when all entries are within retention")
    func purgeNothingToRemove() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)

        let entry = AuditEntry(
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/recent", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(entry)

        let purged = try writer.purgeEntries()
        #expect(purged == 0)
    }

    @Test("purgeEntries with custom retention period")
    func purgeCustomRetention() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()

        // Entry from 10 days ago
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-10 * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/test", size: 100)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 100
        )
        try writer.write(entry)

        // 7-day retention should purge it
        let purged = try writer.purgeEntries(olderThanDays: 7, now: now)
        #expect(purged == 1)

        let remaining = try writer.readEntries()
        #expect(remaining.isEmpty)
    }

    /// Grab the sidecar exclusively, the way a second process would.
    private func holdSidecarLock(in dir: URL) -> Int32 {
        let fd = Darwin.open(dir.appendingPathComponent("audit.lock").path, O_WRONLY | O_CREAT, 0o644)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        return fd
    }

    @Test("An append blocks while another process holds the audit lock")
    func writeWaitsForSidecarLock() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir, lockTimeout: 5)
        // Materialize the log and the sidecar before taking the lock.
        try writer.write(makeEntry(path: "/seed"))

        let held = holdSidecarLock(in: dir)

        let finished = OSAllocatedUnfairLock(initialState: false)
        let make = makeEntry
        let thread = Thread {
            try? writer.write(make("/blocked", 0, Date()))
            finished.withLock { $0 = true }
        }
        thread.start()

        Thread.sleep(forTimeInterval: 0.25)
        #expect(finished.withLock { $0 } == false, "write must not proceed while the sidecar is locked")

        _ = flock(held, LOCK_UN)
        Darwin.close(held)

        let deadline = Date().addingTimeInterval(5)
        while !finished.withLock({ $0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(finished.withLock { $0 }, "write must complete once the sidecar is released")

        let paths = try writer.readEntries().flatMap { $0.files.map(\.path) }
        #expect(paths.contains("/blocked"))
    }

    @Test("A retention purge blocks while another process holds the audit lock")
    func purgeWaitsForSidecarLock() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir, lockTimeout: 5)
        let now = Date()
        try writer.write(makeEntry(path: "/old", age: -100 * 86400, now: now))

        let held = holdSidecarLock(in: dir)

        let purged = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let thread = Thread {
            let count = try? writer.purgeEntries(olderThanDays: 90, now: now)
            purged.withLock { $0 = count }
        }
        thread.start()

        Thread.sleep(forTimeInterval: 0.25)
        #expect(purged.withLock { $0 } == nil, "purge must not proceed while the sidecar is locked")

        _ = flock(held, LOCK_UN)
        Darwin.close(held)

        let deadline = Date().addingTimeInterval(5)
        while purged.withLock({ $0 }) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(purged.withLock { $0 } == 1)
    }

    @Test("Appends interleaved with purges are never lost")
    func appendsSurviveConcurrentPurges() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let now = Date()
        let seed = AuditWriter(logDirectory: dir, lockTimeout: 5)
        // Seed at staggered ages so each purge round below, with its
        // progressively tighter retention window, has fresh entries to drop.
        let make = makeEntry
        for i in 0 ..< 60 {
            try seed.write(make("/old\(i)", Double(-(200 - i)) * 86400, now))
        }

        let appendCount = 40
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // A separate instance, standing in for the MCP server process.
                let purger = AuditWriter(logDirectory: dir, lockTimeout: 5)
                // Each round shrinks the retention window so it drops ~3 more of the
                // staggered old entries — every round performs a real inode-swapping
                // rewrite, rather than only the first one doing so.
                for r in 0 ..< 20 {
                    _ = try purger.purgeEntries(olderThanDays: 199 - r * 3, now: now)
                }
            }
            for i in 0 ..< appendCount {
                group.addTask {
                    let writer = AuditWriter(logDirectory: dir, lockTimeout: 5)
                    try writer.write(make("/fresh\(i)", 0, Date()))
                }
            }
            try await group.waitForAll()
        }

        let paths = Set(try AuditWriter(logDirectory: dir).readEntries().flatMap { $0.files.map(\.path) })
        for i in 0 ..< appendCount {
            #expect(paths.contains("/fresh\(i)"), "append /fresh\(i) was lost across a concurrent purge")
        }
    }

    @Test("A purge fails rather than proceeding unlocked when the sidecar stays held")
    func purgeFailsWhenSidecarLockTimesOut() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir, lockTimeout: 0.2)
        let now = Date()
        try writer.write(makeEntry(path: "/old", age: -100 * 86400, now: now))

        let held = holdSidecarLock(in: dir)
        defer { _ = flock(held, LOCK_UN); Darwin.close(held) }

        // Retention is deferrable; running the read-modify-write unlocked is
        // the exact hazard the sidecar exists to prevent.
        #expect(throws: AuditWriteError.self) {
            _ = try writer.purgeEntries(olderThanDays: 90, now: now)
        }

        // The log must be untouched — a failed purge purges nothing.
        let remaining = try writer.readEntries()
        #expect(remaining.count == 1)
    }

    @Test("An append still lands when the sidecar stays held")
    func writeFallsBackWhenSidecarLockTimesOut() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir, lockTimeout: 0.2)
        try writer.write(makeEntry(path: "/seed"))

        let held = holdSidecarLock(in: dir)
        defer { _ = flock(held, LOCK_UN); Darwin.close(held) }

        // Dropping an audit record is worse than appending without exclusion:
        // the O_APPEND write is still kernel-atomic, so the line lands whole.
        try writer.write(makeEntry(path: "/fallback"))

        let paths = try writer.readEntries().flatMap { $0.files.map(\.path) }
        #expect(paths.contains("/fallback"))
    }
}
