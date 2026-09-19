import Foundation
@testable import GargantuaCore

/// Shared on-disk fixture for the AI session adapter suites.
///
/// Lives in its own file so each suite stays within the project's type-body
/// limit, and so the orphan and scratchpad tests build their trees the same way.
final class AISessionFixtureTree {
    /// A fixed "now" so every age assertion is deterministic.
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let day: TimeInterval = 86_400

    let root: URL
    let claudeProjects: URL
    let workspaceStorage: URL
    /// Stands in for `/Volumes` so the mount guard can be exercised without
    /// mounting anything.
    let volumes: URL
    /// Stands in for `/private/tmp/claude-<uid>`.
    let scratchpadRoot: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISessionScanAdapterTests-\(UUID().uuidString)", isDirectory: true)
        claudeProjects = root.appendingPathComponent("claude/projects", isDirectory: true)
        workspaceStorage = root.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        scratchpadRoot = root.appendingPathComponent("claude-501", isDirectory: true)
        try fm.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)
        try fm.createDirectory(at: volumes, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratchpadRoot, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    /// Writes `<projects>/<slug>/session.jsonl`, optionally recording `cwd`.
    /// `padding` is appended as a trailing record so the transcript can be
    /// pushed past a probe limit.
    func addClaudeProject(slug: String, cwd: String?, padding: String = "") throws {
        let dir = claudeProjects.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var lines = ["{\"type\":\"summary\"}"]
        if let cwd {
            lines.append("{\"type\":\"user\",\"cwd\":\"\(cwd)\"}")
        }
        if !padding.isEmpty {
            lines.append("{\"type\":\"user\",\"text\":\"\(padding)\"}")
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

    /// Builds `<scratchpadRoot>/<project>/<session>/scratchpad/` with a file
    /// at the top and optionally one nested deeper, each aged independently
    /// of the session folder itself.
    func addScratchpad(
        project: String,
        session: String,
        contentAge: TimeInterval,
        nestedContentAge: TimeInterval? = nil,
        folderAge: TimeInterval? = nil
    ) throws {
        let sessionDir = scratchpadRoot
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        let scratch = sessionDir.appendingPathComponent("scratchpad", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        let top = scratch.appendingPathComponent("notes.txt")
        try Data(repeating: 0x1, count: 128).write(to: top)
        try fm.setAttributes(
            [.modificationDate: AISessionFixtureTree.now.addingTimeInterval(-contentAge)],
            ofItemAtPath: top.path
        )

        if let nestedContentAge {
            let nested = scratch.appendingPathComponent("build/out", isDirectory: true)
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            let deep = nested.appendingPathComponent("artifact.bin")
            try Data(repeating: 0x2, count: 128).write(to: deep)
            try fm.setAttributes(
                [.modificationDate: AISessionFixtureTree.now.addingTimeInterval(-nestedContentAge)],
                ofItemAtPath: deep.path
            )
        }

        // Set the folder timestamps last so creating children can't bump them.
        let folderDate = AISessionFixtureTree.now.addingTimeInterval(-(folderAge ?? contentAge))
        for dir in [scratch, sessionDir] {
            try fm.setAttributes([.modificationDate: folderDate], ofItemAtPath: dir.path)
        }
    }

    func makeAdapter(
        categories: Set<String>? = ["dev_artifacts"],
        excludedPaths: Set<String> = [],
        protectedRoots: ProtectedRootPolicy = ProtectedRootPolicy(entries: []),
        transcriptProbeByteLimit: Int = 256 * 1024
    ) -> AISessionScanAdapter {
        AISessionScanAdapter(
            policy: AISessionScanPolicy(
                stores: [
                    AISessionStore(toolName: "Claude Code", kind: .claudeCodeProject, url: claudeProjects),
                    AISessionStore(toolName: "VS Code", kind: .editorWorkspaceStorage, url: workspaceStorage),
                    AISessionStore(toolName: "Claude Code", kind: .agentScratchpad, url: scratchpadRoot),
                ],
                excludedPaths: excludedPaths,
                protectedRoots: protectedRoots,
                transcriptProbeByteLimit: transcriptProbeByteLimit,
                volumesDirectory: volumes
            ),
            categories: categories,
            now: { AISessionFixtureTree.now }
        )
    }
}
