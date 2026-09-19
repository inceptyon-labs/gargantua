import Foundation

/// Discovery for `AISessionStoreKind.agentScratchpad` — the working directories
/// an agent session is handed under `/private/tmp/claude-<uid>`.
///
/// Split from the main adapter file to stay within the project's type-body
/// limit; the logic is unchanged.
extension AISessionScanAdapter {
    // MARK: - Agent scratchpads

    /// Surfaces `<store>/<project-slug>/<session-id>` directories that nothing
    /// has written to in `scratchpadStaleAfter`.
    ///
    /// The unit is the whole session directory, and its age is the newest file
    /// found anywhere inside it. Both matter: a scratchpad holds one session's
    /// working files, so removing part of it is meaningless, and writing a file
    /// does not touch its parent directory's timestamp — on a real machine a
    /// session directory read four days stale while its contents were eight
    /// hours old.
    func staleScratchpads(in store: AISessionStore) -> [AISessionFinding] {
        // `/private/tmp` is world-writable, so a scratchpad root must be a real
        // directory this user owns before anything under it is believed.
        guard ownedRealDirectory(store.url) else { return [] }

        let transcriptActivity = transcriptActivityBySessionID()
        var out: [AISessionFinding] = []

        for project in childDirectories(of: store.url) where ownedRealDirectory(project) {
            for session in childDirectories(of: project) where ownedRealDirectory(session) {
                guard policy.protectionReason(for: session.path) == nil,
                      !policy.isExcluded(path: session.path) else { continue }

                // A partial walk cannot prove inactivity, so it proves nothing.
                guard let metrics = contentMetrics(of: session), metrics.size > 0 else { continue }

                // A session resumed after a long gap appends to its transcript
                // even when it never writes a scratch file, and reads don't move
                // atime on APFS. The transcript is the only evidence of that.
                let sessionID = session.lastPathComponent
                let newest = max(metrics.newestModification, transcriptActivity[sessionID] ?? .distantPast)

                let idle = now().timeIntervalSince(newest)
                guard idle >= policy.scratchpadStaleAfter else { continue }

                out.append(AISessionFinding(
                    toolName: store.toolName,
                    kind: store.kind,
                    path: session.path,
                    reason: .inactive(days: Int(idle / 86_400)),
                    size: metrics.size,
                    lastActivity: newest
                ))
            }
        }

        return out
    }

    /// Newest transcript modification per session id, across every configured
    /// Claude Code project store. Verified on disk: a scratchpad session
    /// directory is named for the session whose transcript is
    /// `~/.claude/projects/<slug>/<session-id>.jsonl`.
    func transcriptActivityBySessionID() -> [String: Date] {
        var newest: [String: Date] = [:]
        for store in policy.stores where store.kind == .claudeCodeProject {
            for project in childDirectories(of: store.url) {
                let transcripts = (try? fileManager.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for transcript in transcripts where transcript.pathExtension == "jsonl" {
                    guard let modified = modificationDate(transcript) else { continue }
                    let sessionID = transcript.deletingPathExtension().lastPathComponent
                    if modified > newest[sessionID] ?? .distantPast {
                        newest[sessionID] = modified
                    }
                }
            }
        }
        return newest
    }

    /// True when `url` is a directory in its own right — not a symlink — and is
    /// owned by the current user.
    ///
    /// Both halves matter under `/private/tmp`, which is world-writable with the
    /// sticky bit: any user can create the predictable `claude-<uid>` name before
    /// the real one exists, and `fileExists(atPath:isDirectory:)` follows
    /// symlinks, so a planted link to a home directory would otherwise make that
    /// directory's contents look like sessions.
    func ownedRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    /// Total size and newest modification date at or under `url`, in one walk,
    /// or `nil` if the tree could not be read completely.
    ///
    /// A scratchpad can hold tens of thousands of files — a session on the
    /// authoring machine held 21,446 — so size and age are collected together
    /// rather than by walking the tree twice.
    ///
    /// Three details are load-bearing:
    ///
    /// - The walk starts from `url`'s own timestamp. The enumerator yields only
    ///   descendants, and moving a file into the session root or deleting one
    ///   from it updates the directory while leaving every remaining descendant
    ///   old, which would otherwise read as inactivity.
    /// - Packages are descended into. A generated `.app` bundle is a directory
    ///   of ordinary files here, and skipping it would hide fresh writes and
    ///   understate the size of what removal would take.
    /// - Any enumeration or metadata failure abandons the whole session. A
    ///   subtree that cannot be read may hold the newest file in it, so a
    ///   partial walk is not evidence of inactivity.
    func contentMetrics(of url: URL) -> (size: Int64, newestModification: Date)? {
        guard var newest = modificationDate(url) else { return nil }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let failed = ReadFailureFlag()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                failed.tripped = true
                return false
            }
        ) else {
            return nil
        }

        var size: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else {
                return nil
            }
            if values.isRegularFile == true {
                size += Int64(values.fileSize ?? 0)
            }
            if let modified = values.contentModificationDate, modified > newest {
                newest = modified
            }
        }
        guard !failed.tripped else { return nil }
        return (size, newest)
    }

    /// Box for the enumerator's error handler, which must escape.
    final class ReadFailureFlag: @unchecked Sendable {
        var tripped = false
    }

    private func childDirectories(of url: URL) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter(isDirectory).sorted { $0.path < $1.path }
    }
}
