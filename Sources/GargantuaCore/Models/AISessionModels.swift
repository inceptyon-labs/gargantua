import Foundation

/// The shape of a per-project session store an AI coding tool keeps.
///
/// Each kind names a different way of recording "which project did this
/// conversation belong to", which is what `AISessionScanAdapter` reads back to
/// decide whether the owning project still exists.
public enum AISessionStoreKind: String, Sendable, Equatable, Codable {
    /// `~/.claude/projects/<slug>` — one directory of JSONL transcripts per
    /// project. The project path is recorded as `cwd` inside the transcript.
    case claudeCodeProject

    /// `<editor>/User/workspaceStorage/<hash>` — one directory of per-workspace
    /// state per project. The project path is recorded as a `file://` URI in
    /// `workspace.json`.
    case editorWorkspaceStorage

    /// `/private/tmp/claude-<uid>/<project-slug>/<session-id>/` — the working
    /// directory an agent session is given for scratch files. Nested one level
    /// deeper than the other kinds, and judged by inactivity rather than by a
    /// missing project, since the slug cannot be decoded back to a path
    /// unambiguously.
    case agentScratchpad
}

/// Why a session store was surfaced.
public enum AISessionStaleReason: Sendable, Equatable {
    /// The project the store belongs to is gone from disk.
    case projectMissing(projectPath: String)
    /// Nothing anywhere inside the store has been written for this long.
    case inactive(days: Int)
}

/// One directory an AI tool fills with per-project session state.
public struct AISessionStore: Sendable, Equatable {
    /// Attribution shown on results from this store (e.g. "Claude Code").
    public let toolName: String
    /// How the project path is recorded inside each entry.
    public let kind: AISessionStoreKind
    /// The directory whose immediate children are per-project entries.
    public let url: URL

    public init(toolName: String, kind: AISessionStoreKind, url: URL) {
        self.toolName = toolName
        self.kind = kind
        self.url = url
    }
}

/// Configuration for `AISessionScanAdapter`.
public struct AISessionScanPolicy: Sendable {
    /// Session stores to examine.
    public let stores: [AISessionStore]
    /// User exclusions: store-entry paths that must never be proposed.
    public let excludedPaths: Set<String>
    /// Global Trust Layer protected-root policy.
    public let protectedRoots: ProtectedRootPolicy
    /// How many leading bytes of a transcript to read looking for the project
    /// path. Bounded so a multi-hundred-megabyte transcript is never loaded.
    public let transcriptProbeByteLimit: Int
    /// How long a scratchpad must go completely untouched before it is
    /// surfaced. Measured against the newest file *anywhere inside* it, not
    /// the directory's own timestamp — writing a file does not update its
    /// parent's mtime, and on a real machine that gap reached four days.
    public let scratchpadStaleAfter: TimeInterval
    /// Where removable volumes are mounted. A seam for tests; in production
    /// this is always `/Volumes`.
    public let volumesDirectory: URL

    public init(
        stores: [AISessionStore],
        excludedPaths: Set<String> = [],
        protectedRoots: ProtectedRootPolicy = ProtectedRootPolicy(entries: []),
        transcriptProbeByteLimit: Int = 256 * 1024,
        scratchpadStaleAfter: TimeInterval = 7 * 24 * 60 * 60,
        volumesDirectory: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) {
        self.stores = stores
        self.excludedPaths = excludedPaths
        self.protectedRoots = protectedRoots
        self.transcriptProbeByteLimit = transcriptProbeByteLimit
        self.scratchpadStaleAfter = scratchpadStaleAfter
        self.volumesDirectory = volumesDirectory
    }

    /// Exclusions are compared in canonical form so a path the user recorded
    /// through a symlinked ancestor (`/var/...`) still matches the same entry
    /// as the scan walks it (`/private/var/...`).
    public func isExcluded(path: String) -> Bool {
        let target = AISessionScanPolicy.canonicalPath(path)
        return excludedPaths.contains { AISessionScanPolicy.canonicalPath($0) == target }
    }

    public func protectionReason(for path: String) -> String? {
        protectedRoots.protectionReason(for: URL(fileURLWithPath: path))
    }

    static func canonicalPath(_ path: String) -> String {
        normalizedPath(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    static func normalizedPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

/// A session store entry that nothing is going to reopen.
public struct AISessionFinding: Sendable, Equatable {
    /// Attribution for the tool that wrote the store.
    public let toolName: String
    /// The shape of store this came from.
    public let kind: AISessionStoreKind
    /// The store entry on disk — the directory that would be removed.
    public let path: String
    /// What makes it reviewable.
    public let reason: AISessionStaleReason
    /// Recursive size of the store entry, in bytes.
    public let size: Int64
    /// Newest modification timestamp inside the entry.
    public let lastActivity: Date?

    public init(
        toolName: String,
        kind: AISessionStoreKind,
        path: String,
        reason: AISessionStaleReason,
        size: Int64,
        lastActivity: Date?
    ) {
        self.toolName = toolName
        self.kind = kind
        self.path = path
        self.reason = reason
        self.size = size
        self.lastActivity = lastActivity
    }
}
