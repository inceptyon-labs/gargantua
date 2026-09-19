import Foundation
import Testing
@testable import GargantuaCore

@Suite("AISessionScanAdapter")
struct AISessionScanAdapterTests {
    @Test("Claude Code project whose cwd is gone surfaces as review")
    func orphanedClaudeProjectSurfaces() async throws {
        let fixture = try FixtureTree()
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
        let fixture = try FixtureTree()
        let live = fixture.root.appendingPathComponent("live/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try fixture.addClaudeProject(slug: "-Users-someone-live", cwd: live.path)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("transcript with no cwd record is never proposed")
    func unreadableProjectPathIgnored() async throws {
        let fixture = try FixtureTree()
        try fixture.addClaudeProject(slug: "-Users-someone-unknown", cwd: nil)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("workspaceStorage entry whose folder is gone surfaces as review")
    func orphanedWorkspaceStorageSurfaces() async throws {
        let fixture = try FixtureTree()
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
        let fixture = try FixtureTree()
        try fixture.addWorkspaceStorage(hash: "def456", key: "workspace", folder: fixture.root.appendingPathComponent("gone/team.code-workspace"))

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
    }

    @Test("percent-encoded folder URI resolves to the decoded path")
    func percentEncodedFolderDecoded() async throws {
        let fixture = try FixtureTree()
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
        let fixture = try FixtureTree()
        try fixture.addClaudeProject(slug: "-Volumes-Ext-acme", cwd: "/Volumes/GargantuaTestsNotMounted/acme")

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("store entry under a protected root is skipped")
    func protectedEntrySkipped() async throws {
        let fixture = try FixtureTree()
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
        let fixture = try FixtureTree()
        let slug = "-Users-someone-gone"
        try fixture.addClaudeProject(slug: slug, cwd: fixture.root.appendingPathComponent("gone/acme").path)

        let adapter = fixture.makeAdapter(
            excludedPaths: [fixture.claudeProjects.appendingPathComponent(slug).path]
        )

        #expect(try await adapter.scan(progress: nil).isEmpty)
    }

    @Test("category gate excludes the adapter when dev_artifacts is absent")
    func categoryGate() async throws {
        let fixture = try FixtureTree()
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

    @Test("cwd nested under payload is read")
    func nestedPayloadCwdRead() {
        let text = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/tmp/hal\"}}\n"
        #expect(AISessionScanAdapter.workingDirectory(inJSONLines: text) == "/tmp/hal")
    }

    // MARK: - Helpers

    private final class FixtureTree {
        let root: URL
        let claudeProjects: URL
        let workspaceStorage: URL
        private let fm = FileManager.default

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AISessionScanAdapterTests-\(UUID().uuidString)", isDirectory: true)
            claudeProjects = root.appendingPathComponent("claude/projects", isDirectory: true)
            workspaceStorage = root.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
            try fm.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
            try fm.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)
        }

        deinit { try? fm.removeItem(at: root) }

        /// Writes `<projects>/<slug>/session.jsonl`, optionally recording `cwd`.
        func addClaudeProject(slug: String, cwd: String?) throws {
            let dir = claudeProjects.appendingPathComponent(slug, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var lines = ["{\"type\":\"summary\"}"]
            if let cwd {
                lines.append("{\"type\":\"user\",\"cwd\":\"\(cwd)\"}")
            }
            try (lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        }

        /// Writes `<workspaceStorage>/<hash>/workspace.json` pointing at `folder`.
        func addWorkspaceStorage(hash: String, key: String, folder: URL) throws {
            let dir = workspaceStorage.appendingPathComponent(hash, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let uri = folder.absoluteString
            try "{\"\(key)\": \"\(uri)\"}"
                .write(to: dir.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
            // Give the entry non-zero size so it isn't filtered as empty.
            try Data(repeating: 0x1, count: 64).write(to: dir.appendingPathComponent("state.vscdb"))
        }

        func makeAdapter(
            categories: Set<String>? = ["dev_artifacts"],
            excludedPaths: Set<String> = [],
            protectedRoots: ProtectedRootPolicy = ProtectedRootPolicy(entries: [])
        ) -> AISessionScanAdapter {
            AISessionScanAdapter(
                policy: AISessionScanPolicy(
                    stores: [
                        AISessionStore(toolName: "Claude Code", kind: .claudeCodeProject, url: claudeProjects),
                        AISessionStore(toolName: "VS Code", kind: .editorWorkspaceStorage, url: workspaceStorage),
                    ],
                    excludedPaths: excludedPaths,
                    protectedRoots: protectedRoots
                ),
                categories: categories
            )
        }
    }
}
