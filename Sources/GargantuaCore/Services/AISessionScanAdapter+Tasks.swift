import Foundation

/// Discovery for `AISessionStoreKind.agentTaskStore` — Roo Code's per-task
/// directories.
///
/// Split from the main adapter file to stay within the project's type-body limit.
extension AISessionScanAdapter {

    // MARK: - Agent tasks

    /// Surfaces `<store>/<task-id>` directories that nothing has written to in
    /// `taskStaleAfter`.
    ///
    /// The unit is the whole task directory, and its age is the newest file
    /// found anywhere inside it: resuming a task rewrites files inside its
    /// directory without moving the directory's own mtime. Names starting with
    /// `_` are Roo's own bookkeeping (it skips them too), and `_index.json` is a
    /// file beside the tasks; hidden names are already skipped.
    func staleTasks(in store: AISessionStore) -> [AISessionFinding] {
        guard ownedRealDirectory(store.url) else { return [] }

        var out: [AISessionFinding] = []
        for task in childDirectories(of: store.url) where ownedRealDirectory(task) {
            guard !task.lastPathComponent.hasPrefix("_"),
                  policy.protectionReason(for: task.path) == nil,
                  !policy.isExcluded(path: task.path) else { continue }

            // A partial walk cannot prove inactivity, so it proves nothing.
            guard let metrics = contentMetrics(of: task), metrics.size > 0 else { continue }

            let idle = now().timeIntervalSince(metrics.newestModification)
            guard idle >= policy.taskStaleAfter else { continue }

            out.append(AISessionFinding(
                toolName: store.toolName,
                kind: store.kind,
                path: task.path,
                reason: .inactive(days: Int(idle / 86_400)),
                size: metrics.size,
                lastActivity: metrics.newestModification
            ))
        }
        return out
    }
}
