import Foundation
import Testing
@testable import GargantuaLicensing

@Suite("TrialClock")
struct TrialClockTests {
    @Test("Fresh storage seeds firstLaunchDate on first read")
    func freshStorageSeedsDate() {
        let storage = InMemoryTrialClockStorage()
        let frozen = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TrialClock(storage: storage, now: { frozen })

        let firstLaunch = clock.firstLaunchDate()

        #expect(firstLaunch == frozen)
        #expect(storage.readFirstLaunchDate() == frozen)
    }

    @Test("daysRemaining returns full window on day zero")
    func dayZeroReturnsFullWindow() {
        let frozen = Date(timeIntervalSince1970: 1_750_000_000)
        let storage = InMemoryTrialClockStorage(initialDate: frozen)
        let clock = TrialClock(storage: storage, now: { frozen })

        #expect(clock.daysRemaining() == 14)
    }

    @Test("daysRemaining shrinks as time advances")
    func daysRemainingShrinks() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let storage = InMemoryTrialClockStorage(initialDate: start)
        let day7 = start.addingTimeInterval(7 * 24 * 60 * 60)
        let clock = TrialClock(storage: storage, now: { day7 })

        #expect(clock.daysRemaining() == 7)
    }

    @Test("daysRemaining is zero exactly at the boundary")
    func boundaryReturnsZero() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let storage = InMemoryTrialClockStorage(initialDate: start)
        let boundary = start.addingTimeInterval(14 * 24 * 60 * 60)
        let clock = TrialClock(storage: storage, now: { boundary })

        #expect(clock.daysRemaining() == 0)
        #expect(clock.isExpired())
    }

    @Test("Backdated clock can't inflate daysRemaining past the trial length")
    func backdatedClockCapsAtTrialLength() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let storage = InMemoryTrialClockStorage(initialDate: start)
        let thirtyDaysEarlier = start.addingTimeInterval(-30 * 24 * 60 * 60)
        let clock = TrialClock(storage: storage, now: { thirtyDaysEarlier })

        #expect(clock.daysRemaining() == 14)
    }

    @Test("daysRemaining stays at zero past expiry")
    func postExpiryStaysZero() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let storage = InMemoryTrialClockStorage(initialDate: start)
        let day30 = start.addingTimeInterval(30 * 24 * 60 * 60)
        let clock = TrialClock(storage: storage, now: { day30 })

        #expect(clock.daysRemaining() == 0)
        #expect(clock.isExpired())
    }

    // MARK: - Migration off the resettable plaintext stamp (N4)

    @Test("Migrating storage adopts the legacy start date and retires the legacy key")
    func migrationAdoptsLegacyDateAndClearsIt() {
        let legacyStart = Date(timeIntervalSince1970: 1_750_000_000)
        let primary = InMemoryTrialClockStorage()
        let legacy = InMemoryTrialClockStorage(initialDate: legacyStart)
        let storage = MigratingTrialClockStorage(primary: primary, legacy: legacy)

        // First read migrates: the original start date is preserved (the trial
        // does not restart), copied into primary, and the legacy key is cleared.
        #expect(storage.readFirstLaunchDate() == legacyStart)
        #expect(primary.readFirstLaunchDate() == legacyStart)
        #expect(legacy.readFirstLaunchDate() == nil)

        // A later reset of the legacy (plaintext) stamp no longer matters —
        // primary is authoritative.
        legacy.writeFirstLaunchDate(Date(timeIntervalSince1970: 9_999_999_999))
        #expect(storage.readFirstLaunchDate() == legacyStart)
    }

    @Test("Migrating storage prefers primary and ignores legacy when primary is set")
    func primaryWinsOverLegacy() {
        let primaryStart = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyStart = Date(timeIntervalSince1970: 1_600_000_000)
        let primary = InMemoryTrialClockStorage(initialDate: primaryStart)
        let legacy = InMemoryTrialClockStorage(initialDate: legacyStart)
        let storage = MigratingTrialClockStorage(primary: primary, legacy: legacy)

        #expect(storage.readFirstLaunchDate() == primaryStart)
        // Legacy is left untouched when no migration was needed.
        #expect(legacy.readFirstLaunchDate() == legacyStart)
    }

    @Test("Fresh install with no legacy stamp seeds normally through the clock")
    func freshInstallSeedsThroughMigratingStorage() {
        let primary = InMemoryTrialClockStorage()
        let legacy = InMemoryTrialClockStorage()
        let storage = MigratingTrialClockStorage(primary: primary, legacy: legacy)
        let frozen = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TrialClock(storage: storage, now: { frozen })

        #expect(clock.firstLaunchDate() == frozen)
        #expect(primary.readFirstLaunchDate() == frozen)
    }
}
