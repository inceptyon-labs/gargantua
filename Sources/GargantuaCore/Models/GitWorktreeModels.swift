import Foundation

/// Configuration for `GitWorktreeScanAdapter`: where to look for git
/// repositories, how stale a linked worktree must be before it is surfaced,
/// and which paths are off-limits.
public struct GitWorktreeScanPolicy: Sendable {
    /// Directories to walk looking for git repositories.
    public let roots: [URL]
    /// A linked worktree whose working directory still exists is only surfaced
    /// once its admin metadata has gone untouched for at least this long.
    public let staleAfter: TimeInterval
    /// How deep to descend under each root looking for a `.git` directory.
    public let maxDepth: Int
    /// Directory names skipped during the repo walk (heavy/irrelevant trees).
    public let skippedDirectoryNames: Set<String>
    /// User exclusions: worktree paths that must never be proposed.
    public let excludedPaths: Set<String>
    /// Global Trust Layer protected-root policy.
    public let protectedRoots: ProtectedRootPolicy

    public init(
        roots: [URL],
        staleAfter: TimeInterval = 30 * 24 * 60 * 60,
        maxDepth: Int = 4,
        skippedDirectoryNames: Set<String> = [
            "node_modules", ".build", "build", "Pods", "DerivedData",
            ".venv", "venv", "vendor", "target", ".next", "dist",
        ],
        excludedPaths: Set<String> = [],
        protectedRoots: ProtectedRootPolicy = ProtectedRootPolicy(entries: [])
    ) {
        self.roots = roots
        self.staleAfter = staleAfter
        self.maxDepth = maxDepth
        self.skippedDirectoryNames = skippedDirectoryNames
        self.excludedPaths = excludedPaths
        self.protectedRoots = protectedRoots
    }

    public func isExcluded(path: String) -> Bool {
        excludedPaths.contains(path)
            || excludedPaths.contains(GitWorktreeScanPolicy.normalizedPath(path))
    }

    public func protectionReason(for path: String) -> String? {
        protectedRoots.protectionReason(for: URL(fileURLWithPath: path))
    }

    static func normalizedPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

/// Why a linked worktree was surfaced for review.
public enum GitWorktreeStaleReason: Sendable, Equatable {
    /// The working directory is gone; `git worktree prune` would remove it.
    case prunable
    /// The worktree still exists but its admin metadata is older than the
    /// configured staleness window.
    case inactive(days: Int)
}

/// A single linked git worktree discovered during a scan.
public struct GitWorktreeCandidate: Sendable, Equatable {
    /// The repository that owns the worktree (the main working tree).
    public let repositoryName: String
    /// The worktree admin name under `.git/worktrees/<name>`.
    public let worktreeName: String
    /// The on-disk worktree path (may no longer exist when `prunable`).
    public let path: String
    /// The registration under `.git/worktrees/<name>`.
    public let adminPath: String
    /// Bytes reclaimable: the worktree tree if present, else its admin dir.
    public let size: Int64
    /// Newest admin-metadata timestamp (proxy for last activity).
    public let lastActivity: Date?
    /// Why this worktree is review-worthy.
    public let reason: GitWorktreeStaleReason

    public init(
        repositoryName: String,
        worktreeName: String,
        path: String,
        adminPath: String,
        size: Int64,
        lastActivity: Date?,
        reason: GitWorktreeStaleReason
    ) {
        self.repositoryName = repositoryName
        self.worktreeName = worktreeName
        self.path = path
        self.adminPath = adminPath
        self.size = size
        self.lastActivity = lastActivity
        self.reason = reason
    }
}
