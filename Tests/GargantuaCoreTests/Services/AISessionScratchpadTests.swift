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

    // MARK: - Hardening (third review round)

    @Test("a symlinked project entry is never walked")
    func symlinkedProjectRejected() async throws {
        let fixture = try AISessionFixtureTree()
        // A stand-in for a home directory full of real work.
        let documents = fixture.root.appendingPathComponent("Documents", isDirectory: true)
        let decoy = documents.appendingPathComponent("old-project/scratchpad", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let file = decoy.appendingPathComponent("thesis.txt")
        try Data(repeating: 0x9, count: 256).write(to: file)
        // Age the whole decoy tree: if the containment guard is removed, nothing
        // else may keep this out of the results.
        try fixture.age(
            [file, decoy, documents.appendingPathComponent("old-project"), documents],
            by: 90 * AISessionFixtureTree.day
        )
        // /private/tmp is world-writable, so the project name can be planted.
        try fixture.linkProject(named: "-Users-someone-planted", to: fixture.root.appendingPathComponent("Documents"))

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a session whose tree cannot be read completely is never proposed")
    func unreadableSubtreeSuppressesFinding() async throws {
        try #require(getuid() != 0)

        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 90 * AISessionFixtureTree.day)
        let denied = try fixture.denyRead(
            project: "-Users-someone-acme",
            session: "sess-1",
            subdirectory: "locked",
            age: 90 * AISessionFixtureTree.day
        )
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }

        // The unreadable subtree could hold the newest file in the session, so a
        // partial walk is not evidence of inactivity.
        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("the session directory's own timestamp counts as activity")
    func sessionDirectoryTimestampCounts() async throws {
        let fixture = try AISessionFixtureTree()
        // Every remaining file is old, but something was moved into or deleted
        // from the session root recently, which only moves the directory.
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 90 * AISessionFixtureTree.day)
        try fixture.touchSessionDirectory(project: "-Users-someone-acme", session: "sess-1", age: 1 * AISessionFixtureTree.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("files inside a generated .app bundle count as activity")
    func packageContentsCount() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 90 * AISessionFixtureTree.day)
        try fixture.addPackage(project: "-Users-someone-acme", session: "sess-1", contentAge: 1 * AISessionFixtureTree.day)
        try fixture.touchSessionDirectory(project: "-Users-someone-acme", session: "sess-1", age: 90 * AISessionFixtureTree.day)

        // Skipping package descendants would report this session as 90 days idle.
        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a session resumed without writing scratch files is kept, on transcript evidence")
    func resumedSessionKeptViaTranscript() async throws {
        let fixture = try AISessionFixtureTree()
        let project = "-Users-someone-acme"
        try fixture.addScratchpad(project: project, session: "sess-1", contentAge: 90 * AISessionFixtureTree.day)
        try fixture.touchSessionDirectory(project: project, session: "sess-1", age: 90 * AISessionFixtureTree.day)
        // Resuming appends to the transcript even when nothing is written to the
        // scratchpad, and reads don't move atime on APFS.
        try fixture.addTranscript(project: project, session: "sess-1", age: 1 * AISessionFixtureTree.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a stale session with an equally stale transcript is still proposed")
    func staleSessionWithStaleTranscriptSurfaces() async throws {
        let fixture = try AISessionFixtureTree()
        let project = "-Users-someone-acme"
        try fixture.addScratchpad(project: project, session: "sess-1", contentAge: 90 * AISessionFixtureTree.day)
        try fixture.addTranscript(project: project, session: "sess-1", age: 90 * AISessionFixtureTree.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).count == 1)
    }

    // MARK: - Guards, tested directly

    //
    // The integration tests above can't isolate these: FileManager independently
    // refuses to enumerate through a symlinked directory URL, and a stopped walk
    // yields nothing either way. Both predicates are therefore asserted on their
    // own, so gutting one fails a test.

    @Test("ownedRealDirectory accepts only a real directory this user owns")
    func ownedRealDirectoryPredicate() throws {
        let fixture = try AISessionFixtureTree()
        let adapter = fixture.makeAdapter()
        let fm = FileManager.default

        let real = fixture.root.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        #expect(adapter.ownedRealDirectory(real))

        // The /private/tmp attack: plant the predictable name as a link to a
        // directory full of real work before the genuine root is created.
        let link = fixture.root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(!adapter.ownedRealDirectory(link))

        let file = fixture.root.appendingPathComponent("file.txt")
        try Data(repeating: 0x1, count: 8).write(to: file)
        #expect(!adapter.ownedRealDirectory(file))

        #expect(!adapter.ownedRealDirectory(fixture.root.appendingPathComponent("missing")))
    }

    @Test("contentMetrics reports nothing when the tree cannot be read completely")
    func contentMetricsFailsClosed() throws {
        try #require(getuid() != 0)

        let fixture = try AISessionFixtureTree()
        try fixture.addScratchpad(project: "-Users-someone-acme", session: "sess-1", contentAge: 90 * AISessionFixtureTree.day)
        let session = fixture.scratchpadRoot
            .appendingPathComponent("-Users-someone-acme/sess-1", isDirectory: true)

        // Readable: a real answer.
        #expect(fixture.makeAdapter().contentMetrics(of: session) != nil)

        let denied = try fixture.denyRead(
            project: "-Users-someone-acme",
            session: "sess-1",
            subdirectory: "locked",
            age: 90 * AISessionFixtureTree.day
        )
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }

        // Unreadable subtree: no answer at all, because it may hold the newest file.
        #expect(fixture.makeAdapter().contentMetrics(of: session) == nil)
    }
}
