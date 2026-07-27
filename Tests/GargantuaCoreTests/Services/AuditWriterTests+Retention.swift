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
        let seed = AuditWriter(logDirectory: dir, lockTimeout: 30)
        let make = makeEntry
        // A large log makes each purge round's read-decode-rewrite take real
        // time, so the appends below genuinely land inside the rewrite window
        // rather than racing to finish before the purger starts. Ages are
        // staggered so every round has fresh entries to drop and therefore
        // performs a real inode-swapping rewrite.
        let seedCount = 1200
        for i in 0 ..< seedCount {
            try seed.write(make("/old\(i)", Double(-(400 - i / 4)) * 86400, now))
        }

        // Wall-clock windows, used to prove the two phases actually overlapped.
        let purgeWindow = OSAllocatedUnfairLock<(start: Date, end: Date)?>(initialState: nil)
        let appendWindow = OSAllocatedUnfairLock<(first: Date, last: Date)?>(initialState: nil)
        let purgeDone = OSAllocatedUnfairLock(initialState: false)

        // The purge runs on a real OS thread rather than inside the task
        // group: its 20-round loop never suspends, so as a structured-
        // concurrency Task it can monopolize a cooperative-pool worker and
        // run to completion before any append Task is ever scheduled onto
        // one of the (few, shared-with-the-rest-of-the-suite) other workers
        // — starving out the very overlap this test exists to exercise. A
        // Thread is scheduled preemptively by the kernel instead, so it
        // can't starve the concurrently-running append tasks below.
        //
        // A short pause between rounds (after releasing, before the next
        // acquire) is also needed: back-to-back acquireFileLock calls with
        // no gap let the purge thread win the race against a poller that
        // only retries every 10ms, so under load it can re-take the lock
        // every round without ever truly leaving it up for grabs. Widening
        // that gap gives a waiting append a real window to win it instead.
        let purgeThread = Thread {
            // A separate instance, standing in for the MCP server process.
            let purger = AuditWriter(logDirectory: dir, lockTimeout: 30)
            let start = Date()
            for r in 0 ..< 20 {
                _ = try? purger.purgeEntries(olderThanDays: 399 - r * 4, now: now)
                Thread.sleep(forTimeInterval: 0.015)
            }
            purgeWindow.withLock { $0 = (start: start, end: Date()) }
            purgeDone.withLock { $0 = true }
        }
        purgeThread.start()

        let appendCount = 40
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< appendCount {
                group.addTask {
                    let writer = AuditWriter(logDirectory: dir, lockTimeout: 30)
                    try writer.write(make("/fresh\(i)", 0, Date()))
                    let stamp = Date()
                    appendWindow.withLock { current in
                        guard let existing = current else {
                            current = (first: stamp, last: stamp)
                            return
                        }
                        current = (first: min(existing.first, stamp), last: max(existing.last, stamp))
                    }
                }
            }
            try await group.waitForAll()
        }

        let deadline = Date().addingTimeInterval(30)
        while !purgeDone.withLock({ $0 }), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // Without this the test could pass vacuously: if every append finished
        // before the first rewrite, no line was ever at risk and the assertion
        // below would hold even with the sidecar removed entirely.
        let purged = try #require(purgeWindow.withLock { $0 })
        let appended = try #require(appendWindow.withLock { $0 })
        #expect(
            appended.last > purged.start && appended.first < purged.end,
            "appends and purges did not overlap — the regression window was never exercised"
        )

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

    @Test("An append fails rather than landing unlocked when the sidecar stays held")
    func writeFailsWhenSidecarLockTimesOut() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let writer = AuditWriter(logDirectory: dir, lockTimeout: 0.2)
        try writer.write(makeEntry(path: "/seed"))

        let held = holdSidecarLock(in: dir)
        defer { _ = flock(held, LOCK_UN); Darwin.close(held) }

        // Appending unlocked would land on an inode a rewrite may be about to
        // discard — a silent loss reported as success. Surface the failure.
        #expect(throws: AuditWriteError.self) {
            try writer.write(makeEntry(path: "/rejected"))
        }

        let paths = try writer.readEntries().flatMap { $0.files.map(\.path) }
        #expect(paths == ["/seed"])
    }
}
