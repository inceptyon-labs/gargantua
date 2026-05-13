import Foundation
import Testing
@testable import GargantuaCore

@MainActor
private func makeController() throws -> PersistenceController {
    try PersistenceController(inMemory: true)
}

@Suite("PersistenceController bootstrap and profiles")
@MainActor
struct PersistenceControllerProfilesTests {

    // MARK: - Bootstrap

    @Test("Bootstrap seeds built-in profiles and default settings")
    func bootstrap() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == CleanupProfile.builtIn.count)
        #expect(profiles.contains(where: { $0.id == "developer" }))
        #expect(profiles.contains(where: { $0.id == "light" }))
        #expect(profiles.contains(where: { $0.id == "deep" }))

        let settings = try ctrl.fetchSettings()
        #expect(settings.activeProfileID == "developer")
        #expect(settings.retentionDays == 90)
    }

    @Test("Bootstrap is idempotent — does not duplicate data")
    func bootstrapIdempotent() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()
        try ctrl.bootstrap()
        try ctrl.bootstrap()

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == CleanupProfile.builtIn.count)
    }

    // MARK: - Profiles

    @Test("Save and fetch a custom profile")
    func saveAndFetchProfile() throws {
        let ctrl = try makeController()

        let custom = CleanupProfile(
            id: "custom",
            name: "My Profile",
            description: "Custom test profile",
            categories: ["browser_cache", "system_logs"],
            isCustom: true
        )
        try ctrl.saveProfile(custom)

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == 1)

        let fetched = profiles[0]
        #expect(fetched.id == "custom")
        #expect(fetched.name == "My Profile")
        #expect(fetched.categories == ["browser_cache", "system_logs"])
        #expect(fetched.isCustom == true)
    }

    @Test("Update existing profile preserves ID")
    func updateProfile() throws {
        let ctrl = try makeController()

        let original = CleanupProfile(
            id: "custom",
            name: "Original",
            description: "V1",
            categories: ["browser_cache"],
            isCustom: true
        )
        try ctrl.saveProfile(original)

        let updated = CleanupProfile(
            id: "custom",
            name: "Updated",
            description: "V2",
            categories: ["browser_cache", "system_cache"],
            isCustom: true
        )
        try ctrl.saveProfile(updated)

        let profiles = try ctrl.fetchProfiles()
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Updated")
        #expect(profiles[0].categories.count == 2)
    }

    @Test("Delete profile by ID")
    func deleteProfile() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()

        let beforeCount = try ctrl.fetchProfiles().count
        try ctrl.deleteProfile(id: "light")
        let afterCount = try ctrl.fetchProfiles().count

        #expect(afterCount == beforeCount - 1)
    }

    @Test("Profile with safety overrides round-trips correctly")
    func profileOverridesRoundTrip() throws {
        let ctrl = try makeController()

        try ctrl.saveProfile(.developer)

        let fetched = try ctrl.fetchProfiles().first(where: { $0.id == "developer" })
        #expect(fetched != nil)
        #expect(fetched!.safetyOverrides.count == CleanupProfile.developer.safetyOverrides.count)
        #expect(fetched!.safetyOverrides[0].condition == "age > 30d")
    }
}
