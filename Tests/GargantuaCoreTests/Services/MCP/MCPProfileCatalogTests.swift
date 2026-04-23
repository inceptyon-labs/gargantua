import Testing
@testable import GargantuaCore

@Suite("MCP profile catalog")
struct MCPProfileCatalogTests {

    private static let customProfile = CleanupProfile(
        id: "custom-dev",
        name: "Custom Dev",
        description: "User-defined developer cleanup",
        categories: ["dev_artifacts", "docker"],
        isCustom: true
    )

    @Test("resolves built-in and custom profile identifiers")
    func resolvesBuiltInAndCustomProfiles() throws {
        let catalog = MCPProfileCatalog(
            profiles: CleanupProfile.builtIn + [Self.customProfile],
            activeProfileID: "developer"
        )

        let builtIn = try catalog.resolve("deep")
        let custom = try catalog.resolve("custom-dev")

        #expect(builtIn.id == "deep")
        #expect(custom.id == "custom-dev")
        #expect(custom.isCustom == true)
    }

    @Test("omitted profile resolves to the active custom profile")
    func omittedProfileUsesActiveCustomProfile() throws {
        let catalog = MCPProfileCatalog(
            profiles: CleanupProfile.builtIn + [Self.customProfile],
            activeProfileID: "custom-dev"
        )

        let resolved = try catalog.resolve(nil)

        #expect(resolved.id == "custom-dev")
    }

    @Test("dangling active profile falls back to light")
    func danglingActiveFallsBackToLight() throws {
        let catalog = MCPProfileCatalog(
            profiles: CleanupProfile.builtIn + [Self.customProfile],
            activeProfileID: "missing-active"
        )

        let resolved = try catalog.resolve(nil)

        #expect(resolved.id == "light")
    }

    @Test("unknown profile id throws invalidParams with list_profiles hint")
    func unknownProfileThrowsInvalidParams() throws {
        let catalog = MCPProfileCatalog(
            profiles: CleanupProfile.builtIn + [Self.customProfile],
            activeProfileID: "developer"
        )

        do {
            _ = try catalog.resolve("missing")
            Issue.record("resolve should reject unknown profile IDs")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("Unknown profile 'missing'"))
            #expect(message.contains("list_profiles"))
            #expect(message.contains("custom-dev"))
        }
    }
}
