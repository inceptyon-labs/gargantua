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
                  isVolumeAvailable(for: projectPath),
                  Self.existence(of: projectPath) == .absent else {
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

    /// The leading bytes of a file, truncated at the last complete line.
    ///
    /// The truncation happens on the raw bytes, not on a decoded string: a
    /// newline is a single byte and can never be part of a multi-byte
    /// character, so cutting there leaves valid UTF-8. Decoding first would
    /// throw away the whole probe whenever the byte cap happened to split a
    /// character — and a transcript full of emoji makes that the common case,
    /// not the edge case.
    private func head(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: policy.transcriptProbeByteLimit), !data.isEmpty else {
            return ""
        }
        return Self.decodeCompleteLines(data)
    }

    /// Decodes `data` up to its last newline, dropping any trailing partial record.
    static func decodeCompleteLines(_ data: Data) -> String {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // No complete record in the window — decoding it could only yield a
            // truncated one, which the JSON parser would reject anyway.
            return ""
        }
        // Deliberately the non-failable initializer. `String(bytes:encoding:)`
        // returns nil on a single malformed byte and would throw away an
        // otherwise readable window — the failure this method exists to avoid.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data[..<lastNewline], as: UTF8.self)
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
    /// Two things make that harder to detect than a `/Volumes` prefix check:
    /// the project may be reached through a symlink (`~/external` →
    /// `/Volumes/Drive`), and macOS can leave an empty `/Volumes/<name>`
    /// directory behind after an unclean eject. So the path is resolved through
    /// its deepest existing ancestor first, and the mount point is confirmed by
    /// asking the filesystem which volume it belongs to rather than by its
    /// mere presence.
    private func isVolumeAvailable(for path: String) -> Bool {
        let resolved = resolvedThroughExistingAncestors(path)
        let volumes = AISessionScanPolicy.canonicalPath(policy.volumesDirectory.path)
        guard resolved.hasPrefix(volumes + "/") else { return true }

        let tail = resolved.dropFirst(volumes.count + 1)
        guard let volumeName = tail.split(separator: "/", omittingEmptySubsequences: true).first else {
            return true
        }
        let mountPoint = URL(fileURLWithPath: volumes).appendingPathComponent(String(volumeName), isDirectory: true)
        guard isDirectory(mountPoint) else { return false }
        // A real mount is its own volume root. A leftover empty directory
        // reports the boot volume instead.
        guard let volumeRoot = try? mountPoint.resourceValues(forKeys: [.volumeURLKey]).volume else {
            return false
        }
        return AISessionScanPolicy.canonicalPath(volumeRoot.path)
            == AISessionScanPolicy.canonicalPath(mountPoint.path)
    }

    /// Resolves symlinks in the longest prefix of `path` that exists, then
    /// re-appends the missing tail. `resolvingSymlinksInPath()` alone leaves a
    /// path whose leaf is already gone untouched, which is exactly the case
    /// this adapter is looking at.
    private func resolvedThroughExistingAncestors(_ path: String) -> String {
        var missing: [String] = []
        var cursor = URL(fileURLWithPath: path).standardizedFileURL

        while cursor.path != "/" {
            // lstat, not fileExists: a symlink pointing into an unmounted
            // volume is dangling, and fileExists reports it as absent — which
            // would walk straight past the one link worth following.
            if Self.existence(of: cursor.path) != .absent {
                let base = resolvedSymlinkChain(cursor)
                return missing.reversed().reduce(base) { $0.appendingPathComponent($1) }.path
            }
            missing.append(cursor.lastPathComponent)
            cursor = cursor.deletingLastPathComponent()
        }
        return path
    }

    /// Follows a symlink chain by hand, including links whose destination does
    /// not exist. `resolvingSymlinksInPath()` gives up on a dangling link and
    /// returns it unchanged.
    private func resolvedSymlinkChain(_ url: URL, depth: Int = 0) -> URL {
        guard depth < 16,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url.resolvingSymlinksInPath()
        }
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        return resolvedSymlinkChain(target.standardizedFileURL, depth: depth + 1)
    }

    /// Whether a path is definitively gone, definitively there, or unknowable.
    enum Existence: Equatable {
        case present
        case absent
        /// The filesystem refused to answer — no traversal permission, a TCC
        /// denial, an I/O error. Never evidence that anything was deleted.
        case indeterminate
    }

    /// Distinguishes "this path is gone" from "this path could not be
    /// inspected". `FileManager.fileExists` collapses both into `false`, which
    /// would let a project under a TCC-protected or unreadable directory be
    /// proposed for removal while it is still very much there.
    static func existence(of path: String) -> Existence {
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        switch errno {
        case ENOENT, ENOTDIR, ENAMETOOLONG:
            return .absent
        default:
            return .indeterminate
        }
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
