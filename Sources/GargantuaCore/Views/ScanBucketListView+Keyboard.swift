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
        guard item?.safety != .protected_ else { return }
        toggleSelection(id)
    }

    func selectAllSafe() {
        let safeIDs = displayedResults.filter { $0.safety == .safe }.map(\.id)
        selectedIDs = Set(safeIDs)
    }

    func triggerClean() {
        guard !selectedIDs.isEmpty else { return }
        onClean?()
    }

    func handleEscape() {
        if focusedItemID != nil {
            focusedItemID = nil
        } else {
            onCancel?()
        }
    }

    func jumpToNextGroup() {
        let expandedList = groups.filter { expandedGroupIDs.contains($0.id) && !$0.items.isEmpty }
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
}
