import Foundation

/// Finds per-project AI session stores whose owning project no longer exists.
///
/// AI coding tools keep conversation state keyed by project: Claude Code writes
/// `~/.claude/projects/<slug>/*.jsonl`, and the VS Code family writes
/// `User/workspaceStorage/<hash>/` (which is where Copilot Chat, Cursor, and
/// Windsurf park their per-workspace AI state). Neither is ever garbage
/// collected — delete a checkout and its session store stays behind forever.
///
/// Discovery reads the project path back out of the store itself rather than
/// guessing from the directory name: the `cwd` field in a Claude Code
/// transcript, the `folder`/`workspace` URI in `workspace.json`. An entry is
/// only proposed when that path is definitively gone.
///
/// Everything is classified `.review`. A transcript is user-authored content,
/// and a vanished project may just have moved, so "orphaned" is never "safe".
public struct AISessionScanAdapter: ScanAdapter {
    public static let resultIDPrefix = "ai-session:"
    public static let tag = "ai-session-orphan"
    public static let category = "dev_artifacts"

    private let policy: AISessionScanPolicy
    private let categories: Set<String>?
    // FileManager isn't Sendable, but this adapter only issues read-only,
    // thread-safe queries against it (and defaults to the shared instance).
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        policy: AISessionScanPolicy,
        categories: Set<String>? = nil,
        fileManager: FileManager = .default
    ) {
        self.policy = policy
        self.categories = categories
        self.fileManager = fileManager
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        guard categories == nil || categories?.contains(Self.category) == true else { return [] }
        return discoverOrphans().map(Self.makeScanResult)
    }

    /// Walks every configured store and returns the entries whose project is gone.
    public func discoverOrphans() -> [AISessionOrphan] {
        var seen = Set<String>()
        var discovered: [AISessionOrphan] = []

        for store in policy.stores {
            for orphan in orphans(in: store) {
                guard seen.insert(AISessionScanPolicy.normalizedPath(orphan.path)).inserted else { continue }
                discovered.append(orphan)
            }
        }

        return discovered.sorted { lhs, rhs in
            if lhs.toolName != rhs.toolName {
                return lhs.toolName.localizedStandardCompare(rhs.toolName) == .orderedAscending
            }
            return lhs.projectPath.localizedStandardCompare(rhs.projectPath) == .orderedAscending
        }
    }

    // MARK: - Per-store discovery

    private func orphans(in store: AISessionStore) -> [AISessionOrphan] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: store.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            guard isDirectory(entry) else { return nil }
            guard policy.protectionReason(for: entry.path) == nil,
                  !policy.isExcluded(path: entry.path) else { return nil }

            guard let projectPath = projectPath(forEntry: entry, kind: store.kind),
                  isPlausibleProjectPath(projectPath),
                  isVolumeMounted(for: projectPath),
                  !fileManager.fileExists(atPath: projectPath) else {
                return nil
            }

            let size = DirectorySizeScanner.directorySize(at: entry.path).totalSize
            guard size > 0 else { return nil }

            return AISessionOrphan(
                toolName: store.toolName,
                kind: store.kind,
                path: entry.path,
                projectPath: projectPath,
                size: size,
                lastActivity: newestModification(in: entry)
            )
        }
    }

    private func projectPath(forEntry entry: URL, kind: AISessionStoreKind) -> String? {
        switch kind {
        case .claudeCodeProject:
            return transcriptWorkingDirectory(in: entry)
        case .editorWorkspaceStorage:
            return workspaceFolderPath(in: entry)
        }
    }

    // MARK: - Claude Code transcripts

    /// Reads the `cwd` recorded in the newest transcripts of a project directory.
    ///
    /// Only the first `transcriptProbeByteLimit` bytes of each candidate file are
    /// read — `cwd` appears in the opening records, and transcripts routinely run
    /// to hundreds of megabytes.
    private func transcriptWorkingDirectory(in entry: URL) -> String? {
        let transcripts = (try? fileManager.contentsOfDirectory(
            at: entry,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "jsonl" }
            .sorted { modificationDate($0) ?? .distantPast > modificationDate($1) ?? .distantPast }
            .prefix(3) ?? []

        for transcript in transcripts {
            if let cwd = Self.workingDirectory(inJSONLines: head(of: transcript)) {
                return cwd
            }
        }
        return nil
    }

    /// Scans newline-delimited JSON records for the first usable `cwd` value.
    ///
    /// Records appear at the top level in Claude Code transcripts and nested
    /// under `payload` in Codex-style rollouts, so both are checked.
    static func workingDirectory(inJSONLines text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let cwd = object["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
            if let payload = object["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    /// The leading bytes of a file, truncated at the last complete line so a
    /// record split by the byte cap is never handed to the JSON parser.
    private func head(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: policy.transcriptProbeByteLimit)
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        if data.count == policy.transcriptProbeByteLimit, let lastNewline = text.lastIndex(of: "\n") {
            text = String(text[text.startIndex ..< lastNewline])
        }
        return text
    }

    // MARK: - Editor workspace storage

    /// Reads the workspace a `workspaceStorage/<hash>` entry belongs to.
    private func workspaceFolderPath(in entry: URL) -> String? {
        let manifest = entry.appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // `folder` for a plain folder window, `workspace` for a multi-root
        // `.code-workspace` file. Either way the value is a file:// URI.
        let uri = (object["folder"] as? String) ?? (object["workspace"] as? String)
        guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: - Safety predicates

    /// Rejects paths that would make a removal proposal reckless if the probe
    /// misread a record: relative paths, the filesystem root, and the home
    /// directory itself.
    private func isPlausibleProjectPath(_ path: String) -> Bool {
        let normalized = AISessionScanPolicy.normalizedPath(path)
        guard normalized.hasPrefix("/"), normalized.count > 1 else { return false }
        let home = AISessionScanPolicy.normalizedPath(fileManager.homeDirectoryForCurrentUser.path)
        return normalized != home
    }

    /// True unless the project lives on a volume that is currently unmounted.
    ///
    /// An unplugged external drive makes every project under it look deleted.
    /// Checking that `/Volumes/<name>` is present keeps those stores off the
    /// list until the drive comes back.
    private func isVolumeMounted(for path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2, components[0] == "Volumes" else { return true }
        return isDirectory(URL(fileURLWithPath: "/Volumes/\(components[1])"))
    }

    // MARK: - Filesystem helpers

    private func newestModification(in entry: URL) -> Date? {
        let children = (try? fileManager.contentsOfDirectory(
            at: entry,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
        return (children + [entry]).compactMap(modificationDate).max()
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Result mapping

    private static func makeScanResult(_ orphan: AISessionOrphan) -> ScanResult {
        let what: String
        switch orphan.kind {
        case .claudeCodeProject:
            what = "Conversation transcripts \(orphan.toolName) kept for \(orphan.projectPath)."
        case .editorWorkspaceStorage:
            what = "Per-workspace editor and AI assistant state \(orphan.toolName) kept for \(orphan.projectPath)."
        }

        return ScanResult(
            id: resultIDPrefix + sanitizedID(orphan.path),
            name: "\(orphan.toolName) session store — \(URL(fileURLWithPath: orphan.projectPath).lastPathComponent)",
            path: orphan.path,
            size: orphan.size,
            safety: .review,
            confidence: 76,
            explanation: [
                what,
                "That project folder no longer exists on disk, so nothing will reopen this store.",
                "It still holds your own conversation history, and a missing folder can mean a move rather than a",
                "deletion, so Gargantua marks this review and keeps removal behind confirmation.",
            ].joined(separator: " "),
            source: SourceAttribution(name: orphan.toolName),
            lastAccessed: orphan.lastActivity,
            category: category,
            tags: ["ai_history", "developer", tag, "review"].sorted(),
            regenerates: false
        )
    }

    private static func sanitizedID(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
            .lowercased()
    }
}
