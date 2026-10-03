import Foundation

/// Discovers stale or prunable linked git worktrees and emits review-gated
/// scan items.
///
/// Ported from Mole's `reclaim stale AI agent git worktrees` (tw93/Mole#985).
/// Discovery is filesystem-only — it reads each repository's
/// `.git/worktrees/<name>` admin metadata rather than shelling out to `git`,
/// so it is deterministic, testable, and works whether or not `git` is on PATH.
///
/// Only *linked* worktrees are surfaced; the primary working tree is never
/// touched. Everything is classified `.review` — a worktree can hold
/// uncommitted or unpushed work, so "stale" is never "safe".
public struct GitWorktreeScanAdapter: ScanAdapter {
    public static let resultIDPrefix = "git-worktree:"
    public static let tag = "git-worktree"
    public static let category = "dev_artifacts"

    private let policy: GitWorktreeScanPolicy
    private let categories: Set<String>?
    private let now: @Sendable () -> Date
    // FileManager isn't Sendable, but this adapter only issues read-only,
    // thread-safe queries against it (and defaults to the shared instance).
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        policy: GitWorktreeScanPolicy,
        categories: Set<String>? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.policy = policy
        self.categories = categories
        self.now = now
        self.fileManager = fileManager
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        guard categories == nil || categories?.contains(Self.category) == true else { return [] }
        return discoverCandidates().map(Self.makeScanResult)
    }

    /// Walks the configured roots, finds git repositories, and returns every
    /// linked worktree that is prunable or inactive past the staleness window.
    public func discoverCandidates() -> [GitWorktreeCandidate] {
        var seenWorktreePaths = Set<String>()
        var candidates: [GitWorktreeCandidate] = []

        for repo in repositories() {
            for candidate in linkedWorktrees(in: repo) {
                let key = GitWorktreeScanPolicy.normalizedPath(candidate.path)
                guard seenWorktreePaths.insert(key).inserted else { continue }
                candidates.append(candidate)
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.repositoryName != rhs.repositoryName {
                return lhs.repositoryName.localizedStandardCompare(rhs.repositoryName) == .orderedAscending
            }
            return lhs.worktreeName.localizedStandardCompare(rhs.worktreeName) == .orderedAscending
        }
    }

    // MARK: - Repository discovery

    private func repositories() -> [URL] {
        var seen = Set<String>()
        var repos: [URL] = []
        for root in policy.roots {
            for repo in collectRepositories(in: root, depth: 0)
                where seen.insert(GitWorktreeScanPolicy.normalizedPath(repo.path)).inserted {
                repos.append(repo)
            }
        }
        return repos
    }

    /// Returns repositories found at or under `dir`. A directory containing a
    /// `.git` directory is a repository; the walk stops descending there.
    private func collectRepositories(in dir: URL, depth: Int) -> [URL] {
        guard depth <= policy.maxDepth else { return [] }
        guard let children = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        if children.contains(where: { url in
            url.lastPathComponent == ".git" && isDirectory(url)
        }) {
            return [dir]
        }

        return children.flatMap { child -> [URL] in
            let name = child.lastPathComponent
            guard isDirectory(child),
                  !name.hasPrefix("."),
                  !policy.skippedDirectoryNames.contains(name) else {
                return []
            }
            return collectRepositories(in: child, depth: depth + 1)
        }
    }

    // MARK: - Worktree parsing

    private func linkedWorktrees(in repo: URL) -> [GitWorktreeCandidate] {
        let adminRoot = repo
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        guard let admins = try? fileManager.contentsOfDirectory(
            at: adminRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return admins.compactMap { admin in
            guard isDirectory(admin) else { return nil }
            return candidate(repository: repo, admin: admin)
        }
    }

    private func candidate(repository: URL, admin: URL) -> GitWorktreeCandidate? {
        // A locked worktree is intentionally retained — never propose it.
        if fileManager.fileExists(atPath: admin.appendingPathComponent("locked").path) {
            return nil
        }

        guard let worktreePath = Self.worktreePath(fromAdmin: admin) else { return nil }
        guard policy.protectionReason(for: worktreePath) == nil,
              !policy.isExcluded(path: worktreePath) else {
            return nil
        }

        let lastActivity = newestAdminTimestamp(admin: admin)
        let workingDirExists = isDirectory(URL(fileURLWithPath: worktreePath))

        let reason: GitWorktreeStaleReason
        if !workingDirExists {
            reason = .prunable
        } else if let lastActivity,
                  now().timeIntervalSince(lastActivity) >= policy.staleAfter {
            let days = Int(now().timeIntervalSince(lastActivity) / 86_400)
            reason = .inactive(days: days)
        } else {
            // Active worktree (or no timestamp evidence) — leave it alone.
            return nil
        }

        let size: Int64 = workingDirExists
            ? DirectorySizeScanner.directorySize(at: worktreePath).totalSize
            : DirectorySizeScanner.directorySize(at: admin.path).totalSize

        return GitWorktreeCandidate(
            repositoryName: repository.lastPathComponent,
            worktreeName: admin.lastPathComponent,
            path: worktreePath,
            adminPath: admin.path,
            size: size,
            lastActivity: lastActivity,
            reason: reason
        )
    }

    /// The `gitdir` admin file points at the worktree's `.git` file; the
    /// worktree directory is that file's parent. Git writes it relative to
    /// the admin dir under `worktree.useRelativePaths`.
    static func worktreePath(fromAdmin admin: URL) -> String? {
        guard let gitFile = resolvedPointer(in: admin.appendingPathComponent("gitdir"), prefix: "", base: admin) else {
            return nil
        }
        return gitFile.deletingLastPathComponent().path
    }

    /// The `.git/worktrees/<name>` registration of the linked worktree at
    /// `worktree`, read from its `.git` file (`gitdir: <admin>`). Returns nil
    /// unless that admin dir's own `gitdir` points back at this worktree, so a
    /// crafted `.git` file can't steer removal at another directory.
    public static func adminDirectory(forWorktree worktree: URL) -> URL? {
        guard let admin = resolvedPointer(in: worktree.appendingPathComponent(".git"), prefix: "gitdir:", base: worktree),
              admin.deletingLastPathComponent().lastPathComponent == "worktrees",
              let backPointer = worktreePath(fromAdmin: admin) else {
            return nil
        }
        let worktreePath = worktree.standardizedFileURL.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: backPointer).resolvingSymlinksInPath().path == worktreePath else { return nil }
        return admin
    }

    /// Reads a one-line path pointer file, strips `prefix`, and resolves a
    /// relative path against `base`.
    private static func resolvedPointer(in file: URL, prefix: String, base: URL) -> URL? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(prefix) else { return nil }
        let target = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let url = target.hasPrefix("/") ? URL(fileURLWithPath: target) : base.appendingPathComponent(target)
        return url.standardizedFileURL
    }

    private func newestAdminTimestamp(admin: URL) -> Date? {
        let probes = ["HEAD", "index", "ORIG_HEAD"].map { admin.appendingPathComponent($0) } + [admin]
        return probes.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        .max()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Result mapping

    private static func makeScanResult(_ candidate: GitWorktreeCandidate) -> ScanResult {
        // A prunable worktree's directory is gone; what's left to remove is
        // its registration, exactly what `git worktree prune` deletes. An
        // inactive one is removed as its working tree, and the engine drops
        // the registration with it (`adminDirectory(forWorktree:)`).
        let evidence: String
        let path: String
        switch candidate.reason {
        case .prunable:
            evidence = "Its working directory (\(candidate.path)) is gone, so this removes the stale registration " +
                "in .git/worktrees, as `git worktree prune` would."
            path = candidate.adminPath
        case let .inactive(days):
            evidence = "No worktree activity in \(days) day\(days == 1 ? "" : "s")."
            path = candidate.path
        }

        return ScanResult(
            id: resultIDPrefix + sanitizedID("\(candidate.repositoryName)-\(candidate.worktreeName)-\(candidate.path)"),
            name: "\(candidate.repositoryName) worktree — \(candidate.worktreeName)",
            path: path,
            size: candidate.size,
            safety: .review,
            confidence: 72,
            explanation: [
                "Linked git worktree of \(candidate.repositoryName).",
                evidence,
                "A worktree can hold uncommitted or unpushed work, so Gargantua marks this review and keeps removal behind confirmation.",
            ].joined(separator: " "),
            source: SourceAttribution(name: "Git"),
            lastAccessed: candidate.lastActivity,
            category: category,
            tags: ["developer", "git", tag].sorted(),
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

extension ScanResult {
    /// Whether this result is a linked git worktree (or its stale registration).
    public var isGitWorktree: Bool {
        id.hasPrefix(GitWorktreeScanAdapter.resultIDPrefix)
    }
}
