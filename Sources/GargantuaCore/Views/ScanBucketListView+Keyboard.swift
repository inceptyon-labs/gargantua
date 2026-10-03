import AppKit
import SwiftUI

extension ScanBucketListView {
    func moveFocus(direction: Int) {
        let items = navigableItemIDs
        guard !items.isEmpty else { return }

        guard let current = focusedItemID, let index = items.firstIndex(of: current) else {
            focusedItemID = direction > 0 ? items.first : items.last
            return
        }

        let newIndex = index + direction
        guard items.indices.contains(newIndex) else { return }
        focusedItemID = items[newIndex]
    }

    func toggleFocusedSelection() {
        guard let id = focusedItemID else { return }
        let item = displayedResults.first { $0.id == id }
        guard item?.safety != .protected_, viewOnlyReasons[id] == nil, blockedApps[id] == nil else { return }
        toggleSelection(id)
    }

    func selectAllSafe() {
        let safeIDs = displayedResults
            .filter { $0.safety == .safe && viewOnlyReasons[$0.id] == nil && blockedApps[$0.id] == nil }
            .map(\.id)
        selectedIDs = Set(safeIDs)
    }

    func triggerClean() {
        guard !selectedIDs.isEmpty else { return }
        onClean?()
    }

    /// Esc only clears row focus; leaving the results is the Back button.
    func handleEscape() {
        focusedItemID = nil
    }

    func jumpToNextGroup() {
        let expandedList = groups.filter { isGroupExpanded($0.id) && !$0.items.isEmpty }
        guard !expandedList.isEmpty else { return }

        if let currentID = focusedItemID {
            let currentIdx = expandedList.firstIndex { $0.items.contains { $0.id == currentID } }
            if let idx = currentIdx {
                let nextIdx = (idx + 1) % expandedList.count
                focusedItemID = expandedList[nextIdx].items.first?.id
            } else {
                focusedItemID = expandedList.first?.items.first?.id
            }
        } else {
            focusedItemID = expandedList.first?.items.first?.id
        }
    }

    func deselectAll() {
        selectedIDs = []
    }

    /// Flip selection across every selectable displayed item (protected,
    /// view-only, and app-blocked items stay out). Selections of items not
    /// currently displayed are dropped — invert operates on what's on screen.
    func invertSelection() {
        let selectableIDs = displayedResults
            .filter { $0.safety != .protected_ && viewOnlyReasons[$0.id] == nil && blockedApps[$0.id] == nil }
            .map(\.id)
        selectedIDs = Set(selectableIDs).subtracting(selectedIDs)
    }

    func expandAll() {
        expandAllGroups()
    }

    func collapseAll() {
        listState.collapsedGroupIDs = Set(groups.map(\.id))
    }

    /// Reveal the focused item (or, failing that, the first selected item) in
    /// Finder. "Show me what you're about to delete" — the trust affordance.
    func revealFocusedInFinder() {
        let targetID = focusedItemID ?? selectedIDs.first
        guard let id = targetID,
              let item = displayedResults.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }

    func focusFilterField() {
        guard hasRefinementTools else { return }
        showsRefineControls = true
        isSearchFocused = true
    }

    func handleKey(_ action: () -> Void) -> KeyPress.Result {
        guard !isSuspended else { return .ignored }
        action()
        return .handled
    }

    /// The verbs this surface publishes to the menu bar. Closures are `nil`'d
    /// when they can't apply right now (empty selection, no filter tools) so the
    /// menu items disable themselves and the shortcuts reflect reality.
    var keyboardActions: ResultsKeyboardActions {
        if isSuspended { return ResultsKeyboardActions() }
        return ResultsKeyboardActions(
            selectAll: { selectAllSafe() },
            deselectAll: selectedIDs.isEmpty ? nil : { deselectAll() },
            invertSelection: { invertSelection() },
            expandAll: { expandAll() },
            collapseAll: { collapseAll() },
            cleanSelected: (onClean != nil && !selectedIDs.isEmpty) ? { triggerClean() } : nil,
            revealInFinder: (focusedItemID != nil || !selectedIDs.isEmpty) ? { revealFocusedInFinder() } : nil,
            rescan: onRescan,
            // Nothing is running on the results screen; ⌘. cancels a scan or
            // clean from the console instead.
            cancel: nil,
            focusFilter: hasRefinementTools ? { focusFilterField() } : nil,
            isEditingText: isSearchFocused
        )
    }
}
