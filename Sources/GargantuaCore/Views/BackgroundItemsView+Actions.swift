import AppKit
import SwiftUI

// MARK: - Actions

extension BackgroundItemsView {
    func revealInFinder(_ item: BackgroundItem) {
        guard let plistPath = item.plistPath else { return }
        let url = URL(fileURLWithPath: plistPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func explain(_ item: BackgroundItem) {
        guard let onExplain else { return }
        onExplain(item.toScanResult())
    }

    func startScan() {
        Task { await session.scan() }
    }

    func clearScan() {
        expandedID = nil
        session.clearScan()
    }

    func runAction(_ pending: PendingBackgroundItemAction) async {
        let outcome = await session.perform(pending.action, on: pending.item)
        if !outcome.succeeded, let error = outcome.error {
            lastError = Self.humanReadableError(error)
        }
    }

    static func humanReadableError(_ raw: String) -> String {
        if raw.contains("odesigning failure") || raw.contains("-67028") || raw.contains("errSecCS") {
            return "macOS blocked this action because the helper isn't signed for this build. "
                + "This is expected in debug builds. A release build with Developer ID signing won't hit this."
        }
        if raw.contains("permission") || raw.contains("not permitted") || raw.contains("-60005") {
            return "macOS denied access to this item. It may require Full Disk Access or belong to a system process that can't be modified."
        }
        if raw.contains("No such file") || raw.contains("does not exist") {
            return "The plist file no longer exists on disk. It may have already been removed."
        }
        return raw
    }

    /// If the parent passed a plist path to pre-select, expand the matching
    /// row (and switch to the All filter so it's actually visible) once the
    /// scan has produced an item with that plist path. Clears the binding so
    /// the parent can re-trigger the same handoff later.
    ///
    /// A miss against the cached scan rescans once before reporting the path
    /// missing — the cache can predate the item (an agent added since the
    /// last scan). While a scan is in flight the pre-selection stays pending;
    /// `.onChange(of: session.scan?.scannedAt)` re-enters here once it lands.
    func consumePendingPreSelection() {
        guard let path = preSelectedPlistPath else { return }
        guard let scan = session.scan, !session.isScanning else { return }
        let match = scan.items.first { $0.plistPath == path }
        switch Self.preSelectionStep(
            matchFound: match != nil,
            alreadyRescannedForPath: session.preSelectionRescanPath == path
        ) {
        case .expand:
            guard let match else { return }
            // The path may belong to an item filtered out by the current chip
            // (e.g. Sensitive). Drop back to All so the row actually shows.
            if !filter.apply([match]).contains(where: { $0.id == match.id }) {
                filter = .all
            }
            withAnimation(.easeOut(duration: 0.15)) {
                expandedID = match.id
            }
            preSelectedPlistPath = nil
            session.preSelectionRescanPath = nil
        case .rescanFirst:
            session.preSelectionRescanPath = path
            Task { await session.scan() }
        case .reportMissing:
            // A fresh scan didn't surface the path either — most likely a
            // daemon plist that requires elevated enumeration. Surface as a
            // soft error so the user understands why navigation didn't land
            // somewhere visible.
            lastError = "Could not locate that source in the Background Items list. It may require elevated enumeration."
            preSelectedPlistPath = nil
            session.preSelectionRescanPath = nil
        }
    }

    // `nonisolated`: pure over Sendable value types, and its tests are not
    // @MainActor. See HealthGaugeView for why the build alone won't catch a
    // regression.
    /// What to do with a pending pre-selection given the current scan:
    /// expand on a hit; on a miss, rescan once (the cached scan may predate
    /// the item) before declaring the path missing.
    nonisolated static func preSelectionStep(
        matchFound: Bool,
        alreadyRescannedForPath: Bool
    ) -> PreSelectionStep {
        if matchFound { return .expand }
        return alreadyRescannedForPath ? .reportMissing : .rescanFirst
    }

    enum PreSelectionStep: Equatable {
        case expand
        case rescanFirst
        case reportMissing
    }
}
