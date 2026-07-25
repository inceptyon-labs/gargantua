import Foundation
import Testing
@testable import GargantuaLicensing

@Suite("DestructiveSurface")
struct DestructiveSurfaceTests {
    private func makeGate(
        client: MockPolarClient = MockPolarClient(),
        storage: any LicenseReceiptStorage = InMemoryLicenseReceiptStorage(),
        graceInterval: TimeInterval = LicensePolarConfig.validationGraceInterval,
        trialStorage: any TrialClockStorage = InMemoryTrialClockStorage(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> LicenseGate {
        let store = LicenseStore(
            storage: storage,
            legacyFileURL: nil,
            migrationMarker: InMemoryLicenseMigrationMarker(),
            client: client,
            graceInterval: graceInterval,
            now: now,
            deviceLabel: { "Test Mac" }
        )
        let clock = TrialClock(storage: trialStorage, now: now)
        return LicenseGate(store: store, clock: clock)
    }

    @Test("Raw values are unique")
    func rawValuesAreUnique() {
        let rawValues = DestructiveSurface.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test("Every surface is authorized when the gate allows")
    func everySurfaceAuthorizedWhenAllowed() async {
        let gate = makeGate()

        for surface in DestructiveSurface.allCases {
            let result = await gate.authorize(surface)
            guard case .success(let token) = result else {
                Issue.record("Expected .success for \(surface), got \(result)")
                continue
            }
            #expect(token.surface == surface)
        }
    }

    #if GARGANTUA_LICENSING
        @Test("Every surface is denied authorization when the gate is blocked")
        func everySurfaceDeniedWhenBlocked() async {
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            let storage = InMemoryTrialClockStorage(initialDate: start)
            let day30 = start.addingTimeInterval(30 * 24 * 60 * 60)
            let gate = makeGate(trialStorage: storage, now: { day30 })

            for surface in DestructiveSurface.allCases {
                let result = await gate.authorize(surface)
                guard case .failure(let reason) = result else {
                    Issue.record("Expected .failure for \(surface), got \(result)")
                    continue
                }
                #expect(reason == .trialExpired)
            }
        }
    #endif
}
