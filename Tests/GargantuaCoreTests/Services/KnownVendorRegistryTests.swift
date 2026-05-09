import Foundation
import Testing
@testable import GargantuaCore

@Suite("KnownVendorRegistry")
struct KnownVendorRegistryTests {

    @Test("Lookup returns nil when teamIdentifier is nil")
    func nilTeamReturnsNil() {
        let result = KnownVendorRegistry.default.lookup(
            teamIdentifier: nil,
            bundleIdentifier: "com.foo.bar"
        )
        #expect(result == nil)
    }

    @Test("Lookup returns nil for unknown team identifier")
    func unknownTeamReturnsNil() {
        let result = KnownVendorRegistry.default.lookup(
            teamIdentifier: "ZZZNOTREAL",
            bundleIdentifier: nil
        )
        #expect(result == nil)
    }

    @Test("Sensitive password manager is flagged with category")
    func passwordManagerIsSensitive() throws {
        let result = try #require(KnownVendorRegistry.default.lookup(
            teamIdentifier: "2BUA8C4S2C",
            bundleIdentifier: "com.1password.1password"
        ))
        #expect(result.displayName == "1Password")
        #expect(result.sensitiveCategories == [.passwordManager])
    }

    @Test("Custom registry can include known non-sensitive vendor entries")
    func customRegistryNotSensitive() throws {
        let registry = KnownVendorRegistry(entries: [
            KnownVendorEntry(
                teamIdentifier: "TEAMNS",
                displayName: "Generic Vendor"
            ),
        ])
        let result = try #require(registry.lookup(
            teamIdentifier: "TEAMNS",
            bundleIdentifier: "com.example.app"
        ))
        #expect(result.displayName == "Generic Vendor")
        #expect(result.sensitiveCategories.isEmpty)
    }

    @Test("Default registry contains only sensitive entries")
    func defaultRegistryIsSensitiveOnly() {
        for entry in KnownVendorRegistry.default.entries {
            #expect(!entry.sensitiveCategories.isEmpty,
                    "Default registry entry \(entry.displayName) is non-sensitive — broad team-only matches should be opt-in via custom registries")
        }
    }

    @Test("Bundle-ID-qualified entry preferred over team-only entry")
    func bundleIDQualifiedPreferred() throws {
        let registry = KnownVendorRegistry(entries: [
            KnownVendorEntry(teamIdentifier: "TEAM1", displayName: "Generic"),
            KnownVendorEntry(
                teamIdentifier: "TEAM1",
                bundleIDPrefix: "com.specific.",
                displayName: "Specific Sensitive",
                sensitiveCategories: [.vpn]
            ),
        ])

        let specific = try #require(registry.lookup(
            teamIdentifier: "TEAM1",
            bundleIdentifier: "com.specific.app"
        ))
        #expect(specific.displayName == "Specific Sensitive")
        #expect(specific.sensitiveCategories == [.vpn])

        let generic = try #require(registry.lookup(
            teamIdentifier: "TEAM1",
            bundleIdentifier: "com.other.app"
        ))
        #expect(generic.displayName == "Generic")
        #expect(generic.sensitiveCategories.isEmpty)
    }

    @Test("Bundle-ID-qualified entry without bundleID falls back to team-only")
    func bundleIDQualifiedFallback() throws {
        let registry = KnownVendorRegistry(entries: [
            KnownVendorEntry(teamIdentifier: "TEAM1", displayName: "Generic"),
            KnownVendorEntry(
                teamIdentifier: "TEAM1",
                bundleIDPrefix: "com.specific.",
                displayName: "Specific",
                sensitiveCategories: [.vpn]
            ),
        ])
        let result = try #require(registry.lookup(
            teamIdentifier: "TEAM1",
            bundleIdentifier: nil
        ))
        #expect(result.displayName == "Generic")
    }

    @Test("Default registry covers each sensitive category")
    func defaultRegistryCoversCategories() {
        let allCategories = KnownVendorRegistry.default.entries
            .reduce(into: Set<SensitiveVendorCategory>()) { acc, entry in
                acc.formUnion(entry.sensitiveCategories)
            }
        for expected in SensitiveVendorCategory.allCases {
            #expect(allCategories.contains(expected),
                    "Default registry missing category \(expected.rawValue)")
        }
    }
}

extension SensitiveVendorCategory: CaseIterable {
    public static let allCases: [SensitiveVendorCategory] = [
        .vpn, .passwordManager, .mdm, .accessibility, .backup, .security,
    ]
}
