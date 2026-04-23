import Testing
@testable import GargantuaCore

@Suite("PersistenceController MCP profile catalog")
struct PersistenceMCPProfileCatalogTests {

    @MainActor
    private func makeController() throws -> PersistenceController {
        try PersistenceController(inMemory: true)
    }

    @Test("MCP catalog uses persisted custom profile and active setting")
    @MainActor
    func mcpProfileCatalogUsesPersistedProfiles() throws {
        let ctrl = try makeController()
        try ctrl.bootstrap()

        let custom = CleanupProfile(
            id: "custom-dev",
            name: "Custom Dev",
            description: "User-defined developer cleanup",
            categories: ["dev_artifacts", "docker"],
            isCustom: true
        )
        try ctrl.saveProfile(custom)
        try ctrl.updateSettings { settings in
            settings.activeProfileID = "custom-dev"
        }

        let catalog = try ctrl.fetchMCPProfileCatalog()
        let defaultProfile = try catalog.resolve(nil)
        let explicitCustom = try catalog.resolve("custom-dev")

        #expect(catalog.snapshot.active == "custom-dev")
        #expect(catalog.snapshot.profiles.contains { $0.id == "custom-dev" })
        #expect(defaultProfile.id == "custom-dev")
        #expect(explicitCustom.isCustom == true)
    }
}
