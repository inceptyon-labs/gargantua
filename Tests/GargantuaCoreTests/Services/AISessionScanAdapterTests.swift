import Foundation
import Testing
@testable import GargantuaCore

@Suite("AISessionScanAdapter")
struct AISessionScanAdapterTests {
    @Test("Claude Code project whose cwd is gone surfaces as review")
    func orphanedClaudeProjectSurfaces() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addClaudeProject(slug: "-Users-someone-gone", cwd: fixture.root.appendingPathComponent("gone/acme").path)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.safety == .review)
        #expect(result.category == "dev_artifacts")
        #expect(result.tags.contains("ai-session-orphan"))
        #expect(result.tags.contains("ai_history"))
        #expect(result.name == "Claude Code session store — acme")
        #expect(result.explanation.contains("no longer exists on disk"))
    }

    @Test("Claude Code project whose cwd still exists is left alone")
    func liveClaudeProjectIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        let live = fixture.root.appendingPathComponent("live/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try fixture.addClaudeProject(slug: "-Users-someone-live", cwd: live.path)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("transcript with no cwd record is never proposed")
    func missingCwdRecordIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addClaudeProject(slug: "-Users-someone-unknown", cwd: nil)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("workspaceStorage entry whose folder is gone surfaces as review")
    func orphanedWorkspaceStorageSurfaces() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addWorkspaceStorage(hash: "abc123", key: "folder", folder: fixture.root.appendingPathComponent("gone/widget"))

        let results = try await fixture.makeAdapter().scan(progress: nil)

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.safety == .review)
        #expect(result.name == "VS Code session store — widget")
        #expect(result.explanation.contains("Per-workspace editor and AI assistant state"))
    }

    @Test("multi-root workspace file URI is read from the workspace key")
    func multiRootWorkspaceKeyRead() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addWorkspaceStorage(hash: "def456", key: "workspace", folder: fixture.root.appendingPathComponent("gone/team.code-workspace"))

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
    }

    @Test("percent-encoded folder URI resolves to the decoded path")
    func percentEncodedFolderDecoded() async throws {
        let fixture = try AISessionFixtureTree()
        let live = fixture.root.appendingPathComponent("live/My Project", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try fixture.addWorkspaceStorage(hash: "ghi789", key: "folder", folder: live)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        // The folder exists once decoded, so nothing is proposed. A failure to
        // decode would read it as a missing path and surface a false orphan.
        #expect(results.isEmpty)
    }

    @Test("project on an unmounted volume is treated as absent hardware, not junk")
    func unmountedVolumeIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addClaudeProject(
            slug: "-Volumes-Ext-acme",
            cwd: fixture.volumes.appendingPathComponent("NotMounted/acme").path
        )

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("store entry under a protected root is skipped")
    func protectedEntrySkipped() async throws {
        let fixture = try AISessionFixtureTree()
        let slug = "-Users-someone-gone"
        try fixture.addClaudeProject(slug: slug, cwd: fixture.root.appendingPathComponent("gone/acme").path)

        let adapter = fixture.makeAdapter(protectedRoots: ProtectedRootPolicy(entries: [
            ProtectedRootEntry(
                path: fixture.claudeProjects.appendingPathComponent(slug).path,
                reason: "test-protected",
                source: .user
            ),
        ]))

        #expect(try await adapter.scan(progress: nil).isEmpty)
    }

    @Test("excluded store entry is never proposed")
    func excludedEntrySkipped() async throws {
        let fixture = try AISessionFixtureTree()
        let slug = "-Users-someone-gone"
        try fixture.addClaudeProject(slug: slug, cwd: fixture.root.appendingPathComponent("gone/acme").path)

        let adapter = fixture.makeAdapter(
            excludedPaths: [fixture.claudeProjects.appendingPathComponent(slug).path]
        )

        #expect(try await adapter.scan(progress: nil).isEmpty)
    }

    @Test("category gate excludes the adapter when dev_artifacts is absent")
    func categoryGate() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addClaudeProject(slug: "-Users-someone-gone", cwd: fixture.root.appendingPathComponent("gone/acme").path)

        let adapter = fixture.makeAdapter(categories: ["browser_cache"])

        #expect(try await adapter.scan(progress: nil).isEmpty)
    }

    @Test("a record split by the probe byte cap is not parsed")
    func truncatedTrailingRecordDropped() {
        // The cap lands mid-record; only the first, complete line is JSON.
        let text = "{\"type\":\"user\"}\n{\"cwd\":\"/tmp/hal"
        #expect(AISessionScanAdapter.workingDirectory(inJSONLines: text) == nil)
    }

    @Test("a probe cut through a multi-byte character keeps the complete earlier records")
    func splitCodepointKeepsEarlierRecords() {
        // Decoding the window before trimming would return nil for the whole
        // buffer and silently lose the cwd on the first line.
        var bytes = Array("{\"cwd\":\"/tmp/hal\"}\n".utf8)
        bytes += Array("{\"text\":\"🙂".utf8).dropLast(2)
        let text = AISessionScanAdapter.decodeCompleteLines(Data(bytes))
        #expect(AISessionScanAdapter.workingDirectory(inJSONLines: text) == "/tmp/hal")
    }

    @Test("bounded read still resolves cwd when the cap falls mid-character")
    func boundedReadResolvesCwdPastSplitCharacter() async throws {
        let fixture = try AISessionFixtureTree()
        let gone = fixture.root.appendingPathComponent("gone/acme").path
        // Emoji padding guarantees the byte cap lands inside a character.
        try fixture.addClaudeProject(
            slug: "-Users-someone-gone",
            cwd: gone,
            padding: String(repeating: "🙂", count: 2_000)
        )

        let adapter = fixture.makeAdapter(transcriptProbeByteLimit: 1_024)
        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
    }

    @Test("an unreadable project path is not evidence of deletion")
    func unreadableProjectPathIsIndeterminate() async throws {
        // Running as root bypasses the permission bits this relies on.
        try #require(getuid() != 0)

        let fixture = try AISessionFixtureTree()
        let vault = fixture.root.appendingPathComponent("vault", isDirectory: true)
        let project = vault.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path) }

        #expect(AISessionScanAdapter.existence(of: project.path) == .indeterminate)

        try fixture.addClaudeProject(slug: "-Users-someone-vaulted", cwd: project.path)
        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a leftover mount-point directory does not count as a mounted volume")
    func staleMountPointDirectoryIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        // An empty /Volumes/<name> left behind by an unclean eject: present on
        // disk, but part of the boot volume rather than its own volume root.
        let mountPoint = fixture.volumes.appendingPathComponent("Ext", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try fixture.addClaudeProject(
            slug: "-Volumes-Ext-acme",
            cwd: mountPoint.appendingPathComponent("acme").path
        )

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a project reached through a symlink into an unmounted volume is not an orphan")
    func symlinkedVolumePathIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        // ~/external -> /Volumes/Drive, with Drive unplugged.
        let link = fixture.root.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.volumes.appendingPathComponent("Drive", isDirectory: true)
        )
        try fixture.addClaudeProject(
            slug: "-Users-someone-external-acme",
            cwd: link.appendingPathComponent("acme").path
        )

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("cwd nested under payload is read")
    func nestedPayloadCwdRead() {
        let text = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/tmp/hal\"}}\n"
        #expect(AISessionScanAdapter.workingDirectory(inJSONLines: text) == "/tmp/hal")
    }
}
