import Foundation

/// What one install came to, for an Update All run.
enum AppReleaseInstallAttempt: Equatable {
    case updated
    /// The download turned out to be the version already installed.
    case alreadyCurrent
    case failed
    /// macOS refused to let Gargantua replace the app; the rest would fail too.
    case denied
    /// The license gate refused; nothing was tried.
    case blocked
}

public extension AppReleasesSession {
    var isUpdatingAll: Bool { batch != nil }

    /// Rows on screen that Update All would install. App Store and link-only
    /// rows stay manual, and a row waiting for the user to approve a new
    /// signer needs that answer first.
    var updatableRows: [AppReleaseRow] {
        visibleRows.filter(isUpdatable)
    }

    /// Installs `requested` one at a time, carrying on past a failed app.
    /// Stops early only when every remaining install would fail too.
    ///
    /// - Parameter approved: Bundle IDs the user agreed to quit. An app opened
    ///   after that answer is left alone and reports that it is open.
    func updateAll(_ requested: [AppReleaseRow], quitting approved: Set<String>) async {
        // A check can start while the confirmation is open; the answer still stands.
        await activeTask?.value
        guard batch == nil, !isChecking else { return }
        for asked in requested {
            guard let row = rows.first(where: { $0.id == asked.id }), isUpdatable(row) else { continue }
            installPhases[row.id] = .queued
            installedDuringCheck.insert(row.id)
            batchQueue.append(row.id)
        }
        guard !batchQueue.isEmpty else { return }
        batch = AppReleaseBatchProgress(total: batchQueue.count)
        batchSummary = nil

        var summary = AppReleaseBatchSummary()
        while !batchQueue.isEmpty {
            let id = batchQueue.removeFirst()
            guard let row = rows.first(where: { $0.id == id }),
                  case .available(let candidate, let strategy) = row.status, strategy.isDestructive
            else {
                installPhases[id] = nil
                batch?.total -= 1
                continue
            }
            markStarting(id, strategy: strategy)
            let attempt = await runInstall(
                row, candidate: candidate, strategy: strategy, quitIfRunning: approved.contains(id)
            )
            batch?.finished += 1
            switch attempt {
            case .updated: summary.updated += 1
            case .failed, .denied: summary.needAttention += 1
            case .alreadyCurrent, .blocked: break
            }
            if attempt == .denied || attempt == .blocked { stopUpdateAll() }
        }
        batch = nil
        batchSummary = summary.isEmpty ? nil : summary
    }

    /// Lets the app being updated finish and releases the ones still waiting.
    func stopUpdateAll() {
        for id in batchQueue { installPhases[id] = nil }
        batch?.total -= batchQueue.count
        batchQueue = []
    }
}

extension AppReleasesSession {
    /// Takes an app out of the run, as when the user ignores it while it waits.
    func removeFromBatchQueue(_ bundleID: String) {
        guard let index = batchQueue.firstIndex(of: bundleID) else { return }
        batchQueue.remove(at: index)
        installPhases[bundleID] = nil
        batch?.total -= 1
    }

    private func isUpdatable(_ row: AppReleaseRow) -> Bool {
        guard case .available(_, let strategy) = row.status, strategy.isDestructive,
              installPhases[row.id] == nil
        else { return false }
        if case .signerChanged = rowMessages[row.id] { return false }
        return true
    }
}
