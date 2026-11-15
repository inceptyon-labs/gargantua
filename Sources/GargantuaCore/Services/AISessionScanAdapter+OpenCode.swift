import Foundation

/// Discovery for OpenCode 1.x leftovers: `AISessionStoreKind.openCodeLegacyStorage`
/// and `.openCodeLegacySnapshot`.
extension AISessionScanAdapter {

    // MARK: - Storage

    func staleOpenCodeStorage(in store: AISessionStore) -> [AISessionFinding] {
        let storage = store.url
        guard ownedRealDirectory(storage),
              ownedRealDirectory(storage.appendingPathComponent("session", isDirectory: true)),
              policy.protectionReason(for: storage.path) == nil,
              !policy.isExcluded(path: storage.path) else { return [] }
        // A partial walk cannot prove inactivity, so it proves nothing.
        guard let metrics = contentMetrics(of: storage), metrics.size > 0 else { return [] }
        let idle = now().timeIntervalSince(metrics.newestModification)
        guard idle >= policy.taskStaleAfter else { return [] }
        let finding = AISessionFinding(
            toolName: store.toolName, kind: store.kind, path: storage.path,
            reason: .inactive(days: Int(idle / 86_400)), size: metrics.size,
            lastActivity: metrics.newestModification
        )
        return [finding]
    }

    static func openCodeStorageResult(_ finding: AISessionFinding, days: Int) -> ScanResult {
        ScanResult(
            id: resultIDPrefix + sanitizedID(finding.path),
            name: "\(finding.toolName) 1.x conversation history",
            path: finding.path,
            size: finding.size,
            safety: .review,
            confidence: 72,
            explanation: [
                "Conversations from OpenCode 1.x, kept as JSON files.",
                "OpenCode 2 keeps sessions in opencode.db and never reads or migrates this folder,",
                "so the app can no longer open these conversations, but this folder is their only copy.",
                "Nothing anywhere inside it has been written for \(days) day\(days == 1 ? "" : "s"),",
                "measured against its newest file rather than the folder's own timestamp.",
                "It is one item because each conversation is spread across several of its subfolders;",
                "the undo snapshots next to it are offered separately once no conversation refers to them.",
                "Gargantua marks this review and keeps removal behind confirmation.",
            ].joined(separator: " "),
            source: SourceAttribution(name: finding.toolName),
            lastAccessed: finding.lastActivity,
            category: category,
            tags: ["ai_history", "developer", tag, "review"].sorted(),
            regenerates: false
        )
    }

    // MARK: - Snapshots

    /// The entries git itself creates inside a git directory. A 1.x snapshot
    /// directory holding any other subdirectory is left alone: OpenCode 2.0
    /// nests its store there as `<worktreeHash>/`, and anything else is unexplained.
    static let gitDirectoryLayout: Set<String> = [
        "objects", "refs", "info", "hooks", "logs", "branches", "lfs", "rr-cache",
    ]

    func staleOpenCodeSnapshots(in store: AISessionStore) -> [AISessionFinding] {
        guard ownedRealDirectory(store.url) else { return [] }
        let sessions = store.url.deletingLastPathComponent()
            .appendingPathComponent("storage/session", isDirectory: true)
        var out: [AISessionFinding] = []
        for repository in childDirectories(of: store.url) where ownedRealDirectory(repository) {
            guard policy.protectionReason(for: repository.path) == nil,
                  !policy.isExcluded(path: repository.path),
                  isLegacySnapshotRepository(repository),
                  !hasLegacySessions(in: sessions.appendingPathComponent(repository.lastPathComponent, isDirectory: true))
            else { continue }
            guard let metrics = contentMetrics(of: repository), metrics.size > 0 else { continue }
            let idle = now().timeIntervalSince(metrics.newestModification)
            guard idle >= policy.taskStaleAfter else { continue }
            let config = try? String(contentsOf: repository.appendingPathComponent("config"), encoding: .utf8)
            out.append(AISessionFinding(
                toolName: store.toolName, kind: store.kind, path: repository.path,
                reason: .inactive(days: Int(idle / 86_400)), size: metrics.size,
                lastActivity: metrics.newestModification,
                projectPath: config.flatMap(Self.gitWorktree(inConfig:))
            ))
        }
        return out
    }

    /// True when `url` is a git directory (a regular `HEAD` file and a real
    /// `objects/` directory) whose only subdirectories are git's own.
    func isLegacySnapshotRepository(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.appendingPathComponent("HEAD").path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              ownedRealDirectory(url.appendingPathComponent("objects", isDirectory: true)),
              let children = try? fileManager.contentsOfDirectory(
                  at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
              )
        else { return false }
        return children.allSatisfy { !isDirectory($0) || Self.gitDirectoryLayout.contains($0.lastPathComponent) }
    }

    /// Whether any 1.x session for this project remains under
    /// `storage/session/<projectID>/`. Anything but a definite "no" (the folder
    /// is unreadable, or lists any entry) counts as a reference.
    func hasLegacySessions(in projectSessions: URL) -> Bool {
        switch Self.existence(of: projectSessions.path) {
        case .absent: return false
        case .indeterminate: return true
        case .present:
            guard let entries = try? fileManager.contentsOfDirectory(atPath: projectSessions.path) else { return true }
            return !entries.isEmpty
        }
    }

    /// The `worktree` value from a git config, which OpenCode 1.x set to the
    /// project folder. Used only to label the result.
    static func gitWorktree(inConfig text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "worktree" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func openCodeSnapshotResult(_ finding: AISessionFinding, days: Int) -> ScanResult {
        let label = finding.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? URL(fileURLWithPath: finding.path).lastPathComponent
        return ScanResult(
            id: resultIDPrefix + sanitizedID(finding.path),
            name: "\(finding.toolName) 1.x snapshots — \(label)",
            path: finding.path,
            size: finding.size,
            safety: .review,
            confidence: 72,
            explanation: [
                "A separate git repository OpenCode 1.x kept\(finding.projectPath.map { " of \($0)" } ?? "")"
                    + " so a session could undo its edits.",
                "Your project's own git history is not in it.",
                "No OpenCode 1.x conversation for this project remains, and OpenCode 2 has no store inside it,",
                "so nothing refers to this repository any more.",
                "Nothing anywhere inside it has been written for \(days) day\(days == 1 ? "" : "s").",
                "It can hold copies of the project's files, including untracked ones,",
                "so Gargantua marks this review and keeps removal behind confirmation.",
            ].joined(separator: " "),
            source: SourceAttribution(name: finding.toolName),
            lastAccessed: finding.lastActivity,
            category: category,
            tags: ["ai_history", "developer", tag, "review"].sorted(),
            regenerates: false
        )
    }
}
