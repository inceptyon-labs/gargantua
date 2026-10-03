import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScheduledScanCronExpression DST")
struct ScheduledScanCronDSTTests {
    @Test("Custom cron runs once on the DST fall-back day and still runs on spring-forward day")
    func cronHandlesDSTTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        func utc(_ iso: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: iso)) }

        // Nov 1 2026: 1:00–1:59 happens twice (EDT, then EST).
        let fallBack = try #require(ScheduledScanCronExpression("30 1 * * *"))
        #expect(!fallBack.matchesSinceLastRun(
            now: try utc("2026-11-01T06:31:00Z"), // 1:31 EST, the second 1:30 just passed
            lastRunDate: try utc("2026-11-01T05:30:00Z"), // ran at 1:30 EDT
            lookbackSeconds: 300,
            calendar: calendar
        ))

        // Mar 8 2026: 2:00–2:59 never happens; a 2:30 job runs right after.
        let springForward = try #require(ScheduledScanCronExpression("30 2 * * *"))
        #expect(springForward.matchesSinceLastRun(
            now: try utc("2026-03-08T07:01:00Z"), // 3:01 EDT
            lastRunDate: try utc("2026-03-07T07:30:00Z"), // yesterday 2:30 EST
            lookbackSeconds: 300,
            calendar: calendar
        ))
    }
}
