import Testing
@testable import GargantuaCore

@Suite("AppReleaseBadge")
struct AppReleaseBadgeTests {
    @Test("A checked session wins over the stored count")
    func checkedSessionWins() {
        #expect(AppReleaseBadge.count(
            sessionHasChecked: true, sessionCount: 2, backgroundCheckEnabled: true, storedCount: 5
        ) == 2)
        #expect(AppReleaseBadge.count(
            sessionHasChecked: true, sessionCount: 0, backgroundCheckEnabled: true, storedCount: 5
        ) == 0)
    }

    @Test("An unchecked session uses the stored count only when background checks are on")
    func uncheckedSession() {
        #expect(AppReleaseBadge.count(
            sessionHasChecked: false, sessionCount: 0, backgroundCheckEnabled: true, storedCount: 3
        ) == 3)
        #expect(AppReleaseBadge.count(
            sessionHasChecked: false, sessionCount: 0, backgroundCheckEnabled: false, storedCount: 3
        ) == 0)
    }
}
