import Testing
import Foundation
@testable import GargantuaCore

@Suite("OrganizerBackendPreference")
struct OrganizerBackendPreferenceTests {

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "organizer-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Defaults to .local when nothing is stored")
    func defaultsToLocal() {
        let defaults = Self.makeDefaults()
        #expect(OrganizerBackendPreference.stored(in: defaults) == .local)
    }

    @Test("Stored value round-trips through UserDefaults")
    func storeRoundTrip() {
        let defaults = Self.makeDefaults()
        OrganizerBackendPreference.cloud.store(in: defaults)
        #expect(OrganizerBackendPreference.stored(in: defaults) == .cloud)

        OrganizerBackendPreference.local.store(in: defaults)
        #expect(OrganizerBackendPreference.stored(in: defaults) == .local)
    }

    @Test("Unknown raw value falls back to .local (no crash on corrupted prefs)")
    func unknownRawFallsBack() {
        let defaults = Self.makeDefaults()
        defaults.set("garbage-value-from-a-future-version", forKey: OrganizerBackendPreference.userDefaultsKey)
        #expect(OrganizerBackendPreference.stored(in: defaults) == .local)
    }

    @Test("JSON Codable round-trip")
    func codable() throws {
        for value in OrganizerBackendPreference.allCases {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(OrganizerBackendPreference.self, from: data)
            #expect(back == value)
        }
    }

    @Test("All cases have distinct labels and descriptions")
    func metadataDistinct() {
        let labels = Set(OrganizerBackendPreference.allCases.map(\.label))
        let descriptions = Set(OrganizerBackendPreference.allCases.map(\.settingsDescription))
        #expect(labels.count == OrganizerBackendPreference.allCases.count)
        #expect(descriptions.count == OrganizerBackendPreference.allCases.count)
    }
}
