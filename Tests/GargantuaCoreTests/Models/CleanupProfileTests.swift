import Foundation
import Testing
@testable import GargantuaCore

@Suite("CleanupProfile")
struct CleanupProfileTests {
    @Test("Developer profile includes dev artifact categories")
    func developerCategories() {
        let dev = CleanupProfile.developer
        #expect(dev.categories.contains("dev_artifacts"))
        #expect(dev.categories.contains("docker"))
        #expect(dev.categories.contains("homebrew"))
        #expect(dev.categories.contains("browser_cache"))
        #expect(dev.categories.contains("app_cache"))
    }

    @Test("Dev Purge profile is scoped to dev artifact categories only")
    func devPurgeCategories() {
        let purge = CleanupProfile.devPurge
        #expect(purge.categories == ["dev_artifacts", "docker", "homebrew"])
        #expect(!purge.categories.contains("browser_cache"))
        #expect(!purge.categories.contains("system_cache"))
        #expect(!purge.categories.contains("temp_files"))
        #expect(!purge.categories.contains("trash"))
        #expect(!purge.categories.contains("installers"))
    }

    @Test("Light profile is conservative")
    func lightCategories() {
        let light = CleanupProfile.light
        #expect(light.categories.contains("browser_cache"))
        #expect(light.categories.contains("app_cache"))
        #expect(light.categories.contains("trash"))
        #expect(!light.categories.contains("dev_artifacts"))
        #expect(!light.categories.contains("docker"))
    }

    @Test("Deep profile covers everything")
    func deepCategories() {
        let deep = CleanupProfile.deep
        #expect(deep.categories.count > CleanupProfile.developer.categories.count)
        #expect(deep.categories.contains("app_cache"))
        #expect(deep.categories.contains("app_data"))
        #expect(deep.categories.contains("similar_images"))
        #expect(deep.categories.contains("empty_files"))
        #expect(deep.categories.contains("broken_symlinks"))
    }

    @Test("Developer profile has age-based safety override")
    func developerOverrides() {
        let dev = CleanupProfile.developer
        #expect(!dev.safetyOverrides.isEmpty)

        let override = dev.safetyOverrides[0]
        #expect(override.condition == "age > 30d")
        #expect(override.safety == .safe)
        #expect(override.profiles.contains("developer"))
    }

    @Test("Built-in profiles are not marked as custom")
    func builtInNotCustom() {
        for profile in CleanupProfile.builtIn {
            #expect(profile.isCustom == false)
        }
    }

    @Test("Three built-in profiles exist")
    func builtInCount() {
        #expect(CleanupProfile.builtIn.count == 3)
    }

    @Test("resolve returns persisted profile when active ID matches a user override")
    func resolvePrefersPersistedOverride() {
        let customDeep = CleanupProfile(
            id: "deep",
            name: "Deep (customized)",
            description: "User-tweaked deep clean",
            categories: ["custom_only"],
            isCustom: true
        )
        let resolved = CleanupProfile.resolve(
            activeProfileID: "deep",
            persisted: [customDeep],
            fallback: .deep
        )
        #expect(resolved.name == "Deep (customized)")
        #expect(resolved.categories == ["custom_only"])
        #expect(resolved.isCustom)
    }

    @Test("resolve returns built-in profile when no persisted match")
    func resolveFallsBackToBuiltIn() {
        let resolved = CleanupProfile.resolve(
            activeProfileID: "developer",
            persisted: [],
            fallback: .deep
        )
        #expect(resolved.id == "developer")
        #expect(resolved.name == "Developer")
    }

    @Test("resolve finds devPurge even though it is not in builtIn")
    func resolveFindsDevPurge() {
        let resolved = CleanupProfile.resolve(
            activeProfileID: "devPurge",
            persisted: [],
            fallback: .deep
        )
        #expect(resolved.id == "devPurge")
    }

    @Test("resolve falls back to fallback when ID is unknown")
    func resolveUsesFallbackForUnknownID() {
        let resolved = CleanupProfile.resolve(
            activeProfileID: "does-not-exist",
            persisted: [],
            fallback: .deep
        )
        #expect(resolved.id == "deep")
    }

    @Test("resolve returns .deep fallback for empty active ID")
    func resolveUsesFallbackForEmptyID() {
        let resolved = CleanupProfile.resolve(
            activeProfileID: "",
            persisted: [.developer],
            fallback: .deep
        )
        #expect(resolved.id == "deep")
    }

    @Test("Codable round-trip preserves profile with overrides")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(CleanupProfile.developer)
        let decoded = try decoder.decode(CleanupProfile.self, from: data)

        #expect(decoded.id == "developer")
        #expect(decoded.name == "Developer")
        #expect(decoded.safetyOverrides.count == 1)
        #expect(decoded.safetyOverrides[0].condition == "age > 30d")
    }
}

@Suite("AuditEntry")
struct AuditEntryTests {
    @Test("Codable round-trip preserves audit entry")
    func codableRoundTrip() throws {
        let entry = AuditEntry(
            tool: "native",
            command: "clean",
            files: [
                AuditFile(path: "~/Library/Caches/Chrome", size: 10_000_000),
                AuditFile(path: "~/Library/Caches/Safari", size: 5_000_000),
            ],
            safetyLevel: .safe,
            confirmationMethod: .singleButton,
            bytesFreed: 15_000_000
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(AuditEntry.self, from: data)

        #expect(decoded.tool == "native")
        #expect(decoded.command == "clean")
        #expect(decoded.files.count == 2)
        #expect(decoded.safetyLevel == .safe)
        #expect(decoded.confirmationMethod == .singleButton)
        #expect(decoded.cleanupMethod == .trash)
        #expect(decoded.bytesFreed == 15_000_000)
    }

    @Test("Default cleanup method is trash")
    func defaultTrash() {
        let entry = AuditEntry(
            tool: "native",
            command: "clean",
            files: [],
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            bytesFreed: 0
        )
        #expect(entry.cleanupMethod == .trash)
    }
}
