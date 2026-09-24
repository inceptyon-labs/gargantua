import Darwin
import Foundation

// MARK: - Internal
//
// Synchronous scanning and the core recursive sizer, split out of DirectorySizeScanner.swift
// to stay under SwiftLint's file/type length budgets.

extension DirectorySizeScanner {
    /// Back-compat synchronous scan. Blocks the current thread; avoid on the main actor.
    static func scanChildrenSync(
        of directoryPath: String,
        mountRootCheck: @escaping @Sendable (URL) -> (isMountRoot: Bool, isNetwork: Bool) = defaultMountRootCheck
    ) -> [DirectoryItem] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: directoryPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .totalFileAllocatedSizeKey,
                .isSymbolicLinkKey,
                .linkCountKey,
                .mayShareFileContentKey,
            ],
            options: []
        ) else {
            return []
        }

        var items: [DirectoryItem] = []
        var topLevelFilesSize: Int64 = 0
        var topLevelSharedCloneBytes: Int64 = 0
        var topLevelSeenInodes: Set<InodeKey> = []

        for child in contents {
            switch classifyChild(child, fm: fm, mountRootCheck: mountRootCheck) {
            case .skip:
                continue
            case .file(let size):
                let accounting = looseFileAccounting(for: child, allocated: size, seenInodes: &topLevelSeenInodes)
                topLevelFilesSize += accounting.countedSize
                topLevelSharedCloneBytes += accounting.sharedCloneBytes
            case .mountRoot(let isNetwork):
                items.append(DirectoryItem(
                    name: child.lastPathComponent,
                    path: child.path,
                    size: 0,
                    isMountRoot: true,
                    isNetworkVolume: isNetwork
                ))
            case .readableDirectory:
                let result = directorySize(
                    at: child.path,
                    timeout: defaultDirectorySizeTimeout,
                    reportsUnreadableAsPartial: true,
                    explorerAccounting: true
                )
                items.append(DirectoryItem(
                    name: child.lastPathComponent,
                    path: child.path,
                    size: result.totalSize,
                    isPartial: result.isPartial,
                    sharedCloneBytes: result.sharedCloneBytes
                ))
            case .unreadableDirectory:
                items.append(DirectoryItem(
                    name: child.lastPathComponent,
                    path: child.path,
                    size: 0,
                    isPermissionDenied: true
                ))
            }
        }

        if topLevelFilesSize > 0 {
            items.append(DirectoryItem(
                name: "(Files)",
                path: directoryPath + "/(files)",
                size: topLevelFilesSize,
                isFilesAggregate: true,
                sharedCloneBytes: topLevelSharedCloneBytes
            ))
        }

        items.sort { lhs, rhs in
            if lhs.isPermissionDenied != rhs.isPermissionDenied {
                return !lhs.isPermissionDenied
            }
            return lhs.size > rhs.size
        }

        return items
    }

    /// Walk `directories` with `maxConcurrent` parallel sizing tasks in flight,
    /// invoking `yield` whenever a directory's size resolves.
    static func sizeDirectoriesStreaming(
        _ directories: [URL],
        maxConcurrent: Int,
        directorySizeTimeout: Duration?,
        yield: @escaping @Sendable (DirectoryItem) -> Void
    ) async {
        guard !directories.isEmpty else { return }

        await withTaskGroup(of: (URL, DirectorySizeResult)?.self) { group in
            var nextIndex = 0
            let total = directories.count
            var inflight = 0

            func enqueueNext() {
                guard nextIndex < total, !Task.isCancelled else { return }
                let url = directories[nextIndex]
                group.addTask {
                    if Task.isCancelled { return nil }
                    let result = directorySize(
                        at: url.path,
                        timeout: directorySizeTimeout,
                        reportsUnreadableAsPartial: true,
                        explorerAccounting: true
                    )
                    return (url, result)
                }
                inflight += 1
                nextIndex += 1
            }

            for _ in 0 ..< maxConcurrent { enqueueNext() }

            while inflight > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                guard let result = await group.next() else { break }
                inflight -= 1

                // Re-check cancellation between resuming and yielding — if the
                // consumer bailed while we were suspended, drop the result
                // rather than pushing it through a torn-down stream.
                if let (url, directorySize) = result, !Task.isCancelled {
                    yield(DirectoryItem(
                        name: url.lastPathComponent,
                        path: url.path,
                        size: directorySize.totalSize,
                        isPartial: directorySize.isPartial,
                        isSizing: false,
                        sharedCloneBytes: directorySize.sharedCloneBytes
                    ))
                }
                enqueueNext()
            }
        }
    }

    /// Recursively compute the total allocated size of all files under `path`.
    ///
    /// When `reportsUnreadableAsPartial` is true, any entry the enumerator can't
    /// descend into or read resource values for marks the result `isPartial` —
    /// used by the Explorer so a row with unreadable content reads as a lower
    /// bound rather than a silently undercounted total. Other callers leave this
    /// false and see no behavior change.
    ///
    /// When `explorerAccounting` is true (Disk Explorer only): a hard-linked
    /// regular file's allocated size is counted only the first time that
    /// (device, inode) pair is seen in this walk, and files that may share
    /// content with an APFS clone contribute their non-private bytes to
    /// `sharedCloneBytes`. Other callers leave this false and see no behavior
    /// change.
    ///
    /// Hard links are deduped per walk, not per volume: a link shared between
    /// sibling directories isn't deduped across them, so each sibling's row
    /// can count it once.
    static func directorySize(
        at path: String,
        timeout: Duration? = nil,
        reportsUnreadableAsPartial: Bool = false,
        explorerAccounting: Bool = false
    ) -> DirectorySizeResult {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }

        func shouldStop() -> Bool {
            if Task.isCancelled { return true }
            if let deadline, clock.now >= deadline { return true }
            return false
        }

        let unreadableFlag = reportsUnreadableAsPartial ? UnreadableEntryFlag() : nil
        var errorHandler: (@Sendable (URL, Error) -> Bool)?
        if let unreadableFlag {
            errorHandler = { _, _ in
                unreadableFlag.mark()
                return true
            }
        }

        // Count hidden files: removal deletes dot-content too, so excluding it
        // undercounts "space freed" and, worse, sizes an all-hidden remnant dir
        // to 0 — where `size > 0` guards silently drop it and leave the leftover
        // behind. Honest sizing includes everything a delete would remove.
        let resourceKeys: [URLResourceKey] = explorerAccounting
            ? [.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey, .linkCountKey, .mayShareFileContentKey]
            : [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        let resourceKeySet = Set(resourceKeys)

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: errorHandler
        ) else {
            return DirectorySizeResult(totalSize: 0, isPartial: false)
        }

        var total: Int64 = 0
        var sharedCloneBytes: Int64 = 0
        var seenInodes: Set<InodeKey> = []

        for case let fileURL as URL in enumerator {
            if shouldStop() {
                return DirectorySizeResult(totalSize: total, isPartial: true, sharedCloneBytes: sharedCloneBytes)
            }
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeySet) else {
                unreadableFlag?.mark()
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let allocated = Int64(values.totalFileAllocatedSize ?? 0)
            guard explorerAccounting, values.isDirectory != true else {
                total += allocated
                continue
            }

            var countsAllocation = true
            if let linkCount = values.linkCount, linkCount > 1, let key = InodeKey(path: fileURL.path) {
                countsAllocation = seenInodes.insert(key).inserted
            }
            if countsAllocation {
                total += allocated
            }
            if countsAllocation, values.mayShareFileContent == true,
               let privateSize = privateCloneSize(atPath: fileURL.path) {
                sharedCloneBytes += max(allocated - privateSize, 0)
            }
        }
        return DirectorySizeResult(
            totalSize: total,
            isPartial: unreadableFlag?.wasHit ?? false,
            sharedCloneBytes: sharedCloneBytes
        )
    }
}
