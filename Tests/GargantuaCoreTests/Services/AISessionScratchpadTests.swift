import Foundation
import Testing
@testable import GargantuaCore

/// Coverage for `AISessionStoreKind.agentScratchpad` — the working directories
/// an agent session is handed under `/private/tmp/claude-<uid>`.
@Suite("AISessionScanAdapter: agent scratchpads")
struct AISessionScratchpadTests {
    // MARK: - Agent scratchpads

    @Test("scratchpad untouched past the window surfaces as review")
    func staleScratchpadSurfaces() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 30 * AISessionFixtureTree.day)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.safety == .review)
        #expect(result.name == "Claude Code scratchpad — -Users-someone-acme")
        #expect(result.explanation.contains("30 days"))
        #expect(result.tags.contains("temp"))
    }

    @Test("scratchpad written to recently is left alone")
    func activeScratchpadIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 1 * AISessionFixtureTree.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a stale-looking scratchpad folder with fresh contents is left alone")
    func scratchpadAgeComesFromContentsNotFolder() async throws {
        let fixture = try AISessionFixtureTree()
        // The exact shape measured on a real machine: the session folder's own
        // mtime read four days old while a file inside it was hours old,
        // because writing a file does not touch its parent's timestamp.
        try fixture.addScratchpad(
            project: "-Users-someone-kat",
            session: "sess-1",
            contentAge: 8 * 60 * 60,
            folderAge: 30 * AISessionFixtureTree.day
        )

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("scratchpad age is the newest file anywhere inside, not the shallowest")
    func scratchpadAgeIsDeepest() async throws {
        let fixture = try AISessionFixtureTree()
        // Old file at the top, fresh file buried two levels down.
        try fixture.addScratchpad(
            project: "-Users-someone-acme",
            session: "sess-1",
            contentAge: 90 * AISessionFixtureTree.day,
            nestedContentAge: 2 * AISessionFixtureTree.day
        )

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("the whole session directory is the unit, never individual scratch files")
    func scratchpadUnitIsTheSessionDirectory() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(
            project: "-Users-someone-acme",
            session: "sess-1",
            contentAge: 30 * AISessionFixtureTree.day,
            nestedContentAge: 30 * AISessionFixtureTree.day
        )

        let results = try await fixture.makeAdapter().scan(progress: nil)

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.path.hasSuffix("/sess-1"))
    }

    @Test("scratchpad under a protected root is skipped")
    func protectedScratchpadSkipped() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 30 * AISessionFixtureTree.day)

        let adapter = fixture.makeAdapter(protectedRoots: ProtectedRootPolicy(entries: [
            ProtectedRootEntry(
                path: fixture.scratchpadRoot.appendingPathComponent("-Users-someone-acme/sess-1").path,
                reason: "test-protected",
                source: .user
            ),
        ]))

        #expect(try await adapter.scan(progress: nil).isEmpty)
    }
}
