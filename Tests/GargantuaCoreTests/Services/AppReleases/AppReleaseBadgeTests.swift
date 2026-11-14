import Testing
@testable import GargantuaCore

@Suite("AppReleaseBadge")
struct AppReleaseBadgeTests {
    @Test("Loaded results win over the stored count")
    func resultsLoaded() {
        #expect(AppReleaseBadge.count(
            sessionCount: 2, sessionHasChecked: true, backgroundCheckEnabled: true, storedCount: 5
        ) == 2)
        #expect(AppReleaseBadge.count(
            sessionCount: 0, sessionHasChecked: true, backgroundCheckEnabled: false, storedCount: 5
        ) == 0)
    }

    @Test("A session that checked and then released its results uses the stored count")
    func releasedAfterCheck() {
        #expect(AppReleaseBadge.count(
            sessionCount: nil, sessionHasChecked: true, backgroundCheckEnabled: false, storedCount: 3
        ) == 3)
    }

    @Test("A session that never checked uses the stored count only when background checks are on")
    func neverChecked() {
        #expect(AppReleaseBadge.count(
            sessionCount: nil, sessionHasChecked: false, backgroundCheckEnabled: false, storedCount: 3
        ) == 0)
        #expect(AppReleaseBadge.count(
            sessionCount: nil, sessionHasChecked: false, backgroundCheckEnabled: true, storedCount: 3
        ) == 3)
    }
}
