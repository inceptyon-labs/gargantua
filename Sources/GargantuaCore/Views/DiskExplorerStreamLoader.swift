import Foundation

/// Streams a folder's children into `DiskExplorerState` in ~10 Hz batches
/// rather than one state write (sort + re-render) per child.
@MainActor
enum DiskExplorerStreamLoader {
    static func stream(_ path: String, into state: DiskExplorerState) async {
        let pending = PendingDirectoryItems()
        let flusher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                state.upsert(contentsOf: pending.take())
            }
        }
        defer { flusher.cancel() }
        for await item in DirectorySizeScanner.streamChildren(of: path) {
            if Task.isCancelled { return }
            pending.items.append(item)
        }
        flusher.cancel()
        guard !Task.isCancelled else { return }
        state.upsert(contentsOf: pending.take())
    }
}

/// Children streamed for the folder being loaded, waiting for the next batch.
@MainActor
private final class PendingDirectoryItems {
    var items: [DirectoryItem] = []

    func take() -> [DirectoryItem] {
        defer { items.removeAll(keepingCapacity: true) }
        return items
    }
}
