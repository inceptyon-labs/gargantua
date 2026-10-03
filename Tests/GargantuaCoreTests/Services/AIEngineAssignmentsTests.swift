import Foundation
import Testing
@testable import GargantuaCore

@Suite("AIEngineAssignments")
struct AIEngineAssignmentsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "ai-assignments-\(UUID().uuidString)"
        let defaults = TestDefaults.suite(suite)
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Unset jobs return their defaults")
    func defaults() throws {
        let defaults = try makeDefaults()
        #expect(AIEngineAssignments.engine(for: .inlineExplain, in: defaults) == .template)
        #expect(AIEngineAssignments.engine(for: .deeperExplain, in: defaults) == .cloud)
        #expect(AIEngineAssignments.engine(for: .advisory, in: defaults) == .template)
        #expect(AIEngineAssignments.engine(for: .organize, in: defaults) == .template)
        #expect(AIEngineAssignments.engine(for: .maintenance, in: defaults) == .claudeCode)
    }

    @Test("set/engine round-trips a valid assignment")
    func roundTrip() throws {
        let defaults = try makeDefaults()
        AIEngineAssignments.set(.codex, for: .deeperExplain, in: defaults)
        #expect(AIEngineAssignments.engine(for: .deeperExplain, in: defaults) == .codex)
    }

    @Test("An invalid engine for a job is ignored")
    func invalidIgnored() throws {
        let defaults = try makeDefaults()
        // MLX can't do maintenance; the set is a no-op, default stands.
        AIEngineAssignments.set(.mlx, for: .maintenance, in: defaults)
        #expect(AIEngineAssignments.engine(for: .maintenance, in: defaults) == .claudeCode)
    }

    @Test("A stored value that's no longer valid falls back to the default")
    func staleValueFallsBack() throws {
        let defaults = try makeDefaults()
        // Write a raw value directly that the job can't use.
        defaults.set(AIEngineID.template.rawValue, forKey: "ai.assignment.maintenance")
        #expect(AIEngineAssignments.engine(for: .maintenance, in: defaults) == .claudeCode)
    }

    @Test("Organize bridges to OrganizerBackendPreference, mapping template⇄local")
    func organizeBridge() throws {
        let defaults = try makeDefaults()
        // Default: organizer .local reads back as .template.
        #expect(AIEngineAssignments.engine(for: .organize, in: defaults) == .template)

        AIEngineAssignments.set(.cloud, for: .organize, in: defaults)
        #expect(OrganizerBackendPreference.stored(in: defaults) == .cloud)
        #expect(AIEngineAssignments.engine(for: .organize, in: defaults) == .cloud)

        AIEngineAssignments.set(.template, for: .organize, in: defaults)
        #expect(OrganizerBackendPreference.stored(in: defaults) == .local)
    }

    @Test("Choosing a local engine for inline also drives the shared local engine")
    func inlineLocalMirrorsEnginePreference() throws {
        let defaults = try makeDefaults()
        AIEngineAssignments.set(.mlx, for: .inlineExplain, in: defaults)
        #expect(AIEnginePreference.stored(in: defaults) == .mlx)
        #expect(AIEngineAssignments.engine(for: .inlineExplain, in: defaults) == .mlx)

        AIEngineAssignments.set(.template, for: .inlineExplain, in: defaults)
        #expect(AIEnginePreference.stored(in: defaults) == .template)

        // A non-local inline engine doesn't disturb the local engine pref.
        AIEnginePreference.mlx.store(in: defaults)
        AIEngineAssignments.set(.cloud, for: .inlineExplain, in: defaults)
        #expect(AIEnginePreference.stored(in: defaults) == .mlx)
        #expect(AIEngineAssignments.engine(for: .inlineExplain, in: defaults) == .cloud)
    }

    @Test("Choosing a local engine for advisory also drives the shared local engine")
    func advisoryLocalMirrorsEnginePreference() throws {
        let defaults = try makeDefaults()
        AIEngineAssignments.set(.mlx, for: .advisory, in: defaults)
        #expect(AIEnginePreference.stored(in: defaults) == .mlx)
        #expect(AIEngineAssignments.engine(for: .advisory, in: defaults) == .mlx)

        AIEngineAssignments.set(.template, for: .advisory, in: defaults)
        #expect(AIEnginePreference.stored(in: defaults) == .template)

        // A non-local advisory engine doesn't disturb the local engine pref.
        AIEnginePreference.mlx.store(in: defaults)
        AIEngineAssignments.set(.cloud, for: .advisory, in: defaults)
        #expect(AIEnginePreference.stored(in: defaults) == .mlx)
        #expect(AIEngineAssignments.engine(for: .advisory, in: defaults) == .cloud)
    }
}
