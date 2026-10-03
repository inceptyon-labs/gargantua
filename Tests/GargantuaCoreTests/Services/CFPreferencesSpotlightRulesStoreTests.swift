import Foundation
import Testing
@testable import GargantuaCore

/// Exercises the real CFPreferences-backed store against a throwaway domain so
/// the array-shape read/write round-trip is validated without ever touching the
/// live `com.apple.Spotlight` domain.
@Suite("CFPreferencesSpotlightRulesStore")
struct CFPreferencesSpotlightRulesStoreTests {
    private func makeDomain() -> String {
        let domain = "com.inceptyon.gargantua.tests.spotlight-\(UUID().uuidString)"
        TestDefaults.register(domain)
        return domain
    }

    private func seed(_ domain: String, _ values: [String]) {
        CFPreferencesSetAppValue(
            CFPreferencesSpotlightRulesStore.key as CFString,
            values as CFArray,
            domain as CFString
        )
        _ = CFPreferencesAppSynchronize(domain as CFString)
    }

    private func cleanup(_ domain: String) {
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    @Test("reads EnabledPreferenceRules as a flat string array")
    func readsArray() {
        let domain = makeDomain()
        defer { cleanup(domain) }
        seed(domain, ["com.gone.app", "com.apple.tips", "com.flexibits.fantastical2.mac"])

        let store = CFPreferencesSpotlightRulesStore(domain: domain)
        #expect(store.enabledRuleIdentifiers() == ["com.gone.app", "com.apple.tips", "com.flexibits.fantastical2.mac"])
    }

    @Test("write persists the kept array, dropping the rest")
    func writePersistsKeptArray() throws {
        let domain = makeDomain()
        defer { cleanup(domain) }
        seed(domain, ["a", "b", "c"])

        let store = CFPreferencesSpotlightRulesStore(domain: domain)
        try store.write(keptIdentifiers: ["a", "c"])

        #expect(store.enabledRuleIdentifiers() == ["a", "c"])
    }

    @Test("writing an empty kept set removes the key entirely")
    func emptyWriteDeletesKey() throws {
        let domain = makeDomain()
        defer { cleanup(domain) }
        seed(domain, ["only.one"])

        let store = CFPreferencesSpotlightRulesStore(domain: domain)
        try store.write(keptIdentifiers: [])

        #expect(store.enabledRuleIdentifiers().isEmpty)
        let raw = CFPreferencesCopyAppValue(
            CFPreferencesSpotlightRulesStore.key as CFString,
            domain as CFString
        )
        #expect(raw == nil) // key fully removed, not a lingering empty array
    }

    @Test("a missing domain reads as empty, not a crash")
    func missingDomainReadsEmpty() {
        let store = CFPreferencesSpotlightRulesStore(domain: makeDomain())
        #expect(store.enabledRuleIdentifiers().isEmpty)
    }
}
