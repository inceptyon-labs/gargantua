import Foundation
import Testing
@testable import GargantuaCore

@Suite("AuditRetention")
struct AuditRetentionTests {
    private func makeEntry(daysAgo: Double, now: Date) -> AuditEntry {
        AuditEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-daysAgo * 86400),
            tool: "native",
            command: "clean",
            files: [AuditFile(path: "/tmp/retention-\(Int(daysAgo)).txt", size: 1)],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 1,
            status: .completed
        )
    }

    @Test("purgeInBackground drops entries older than the window and keeps the rest")
    func purgesOnlyAgedEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = AuditWriter(logDirectory: dir)
        let now = Date()
        try writer.write(makeEntry(daysAgo: 10, now: now))
        try writer.write(makeEntry(daysAgo: 40, now: now))
        try writer.write(makeEntry(daysAgo: 400, now: now))

        AuditRetention.purgeInBackground(retentionDays: 30, writer: writer, now: now)

        let deadline = Date().addingTimeInterval(5)
        var remaining = try writer.readEntries()
        while Date() < deadline && remaining.count != 1 {
            usleep(20_000)
            remaining = try writer.readEntries()
        }

        #expect(remaining.count == 1)
        #expect(remaining.first?.files.first?.path == "/tmp/retention-10.txt")
    }

    @Test("the offered windows include the persisted default")
    func optionsIncludeDefault() {
        #expect(AuditRetention.options.contains(PersistedSettings().retentionDays))
    }
}
