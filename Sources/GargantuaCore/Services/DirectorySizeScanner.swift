import Foundation

/// Scans directory sizes using FileManager for the Disk Explorer.
///
/// Returns immediate children of a directory with their total sizes (recursively computed).
/// Handles permission-denied paths gracefully by marking them in the result.
public enum DirectorySizeScanner: Sendable {

    /// Maximum number of concurrent `directorySize` computations.
    ///
    /// Capped to avoid saturating the filesystem with parallel recursive walks while
    /// still letting SSD random-I/O parallelism help sizing proceed visibly faster.
    private static let sizingConcurrency = 4

    /// Scan the immediate children of `directoryPath`, returning each child directory
    /// with its recursively computed total size, sorted largest first.
    ///
    /// Files at the top level are aggregated into a single "(Files)" entry.
    /// Permission-denied children are included with `isPermissionDenied = true` and size 0.
    public static func scanChildren(of directoryPath: String) async -> [DirectoryItem] {
        var items: [DirectoryItem] = []
        for await item in streamChildren(of: directoryPath) where !item.isSizing {
            // Drop the `isSizing` placeholder events; we only want final rows.
            items.append(item)
        }
        items.sort { lhs, rhs in
            if lhs.isPermissionDenied != rhs.isPermissionDenied {
                return !lhs.isPermissionDenied
            }
            return lhs.size > rhs.size
        }
        return items
    }

    /// Stream the immediate children of `directoryPath` as their sizes are computed.
    ///
    /// Emission order:
    /// 1. One `isSizing: true` placeholder per readable subdirectory, emitted as soon
    ///    as directory enumeration yields it.
    /// 2. One permission-denied row per unreadable subdirectory (no follow-up event).
    /// 3. One "(Files)" aggregate row if loose files exist at this level.
    /// 4. One `isSizing: false` row per previously-placeheld directory, replacing it by id
    ///    once its recursive size is known. Emitted in size-computation-finish order.
    ///
    /// The stream honors cancellation: if the consuming task is cancelled (typically
    /// because `DiskExplorerView`'s `.task(id:)` restarted with a new path), in-flight
    /// sizing tasks stop enumerating on their next iteration and the stream terminates.
    public static func streamChildren(of directoryPath: String) -> AsyncStream<DirectoryItem> {
        AsyncStream { continuation in
            let task = Task.detached { [continuation] in
                let fm = FileManager.default
                let url = URL(fileURLWithPath: directoryPath)

                guard let contents = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .totalFileAllocatedSizeKey,
                        .isSymbolicLinkKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.finish()
                    return
                }

                var subdirectoriesToSize: [URL] = []
                var topLevelFilesSize: Int64 = 0

                for child in contents {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                        continue
                    }

                    let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDirectory {
                        if fm.isReadableFile(atPath: child.path) {
                            continuation.yield(DirectoryItem(
                                name: child.lastPathComponent,
                                path: child.path,
                                size: 0,
                                isSizing: true
                            ))
                            subdirectoriesToSize.append(child)
                        } else {
                            continuation.yield(DirectoryItem(
                                name: child.lastPathComponent,
                                path: child.path,
                                size: 0,
                                isPermissionDenied: true
                            ))
                        }
                    } else {
                        let fileSize = (try? child.resourceValues(
                            forKeys: [.totalFileAllocatedSizeKey]
                        ))?.totalFileAllocatedSize ?? 0
                        topLevelFilesSize += Int64(fileSize)
                    }
                }

                if topLevelFilesSize > 0 {
                    continuation.yield(DirectoryItem(
                        name: "(Files)",
                        path: directoryPath + "/(files)",
                        size: topLevelFilesSize,
                        isFilesAggregate: true
                    ))
                }

                await sizeDirectoriesStreaming(
                    subdirectoriesToSize,
                    maxConcurrent: sizingConcurrency,
                    yield: { continuation.yield($0) }
                )

                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internal

    /// Back-compat synchronous scan. Blocks the current thread; avoid on the main actor.
    static func scanChildrenSync(of directoryPath: String) -> [DirectoryItem] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: directoryPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [DirectoryItem] = []
        var topLevelFilesSize: Int64 = 0

        for child in contents {
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }

            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                if fm.isReadableFile(atPath: child.path) {
                    let size = directorySize(at: child.path)
                    items.append(DirectoryItem(
                        name: child.lastPathComponent,
                        path: child.path,
                        size: size
                    ))
                } else {
                    items.append(DirectoryItem(
                        name: child.lastPathComponent,
                        path: child.path,
                        size: 0,
                        isPermissionDenied: true
                    ))
                }
            } else {
                let fileSize = (try? child.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]
                ))?.totalFileAllocatedSize ?? 0
                topLevelFilesSize += Int64(fileSize)
            }
        }

        if topLevelFilesSize > 0 {
            items.append(DirectoryItem(
                name: "(Files)",
                path: directoryPath + "/(files)",
                size: topLevelFilesSize,
                isFilesAggregate: true
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
    private static func sizeDirectoriesStreaming(
        _ directories: [URL],
        maxConcurrent: Int,
        yield: @escaping @Sendable (DirectoryItem) -> Void
    ) async {
        guard !directories.isEmpty else { return }

        await withTaskGroup(of: (URL, Int64)?.self) { group in
            var nextIndex = 0
            let total = directories.count
            var inflight = 0

            func enqueueNext() {
                guard nextIndex < total, !Task.isCancelled else { return }
                let url = directories[nextIndex]
                group.addTask {
                    if Task.isCancelled { return nil }
                    let size = directorySize(at: url.path)
                    return (url, size)
                }
                inflight += 1
                nextIndex += 1
            }

            for _ in 0..<maxConcurrent { enqueueNext() }

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
                if let (url, size) = result, !Task.isCancelled {
                    yield(DirectoryItem(
                        name: url.lastPathComponent,
                        path: url.path,
                        size: size,
                        isSizing: false
                    ))
                }
                enqueueNext()
            }
        }
    }

    /// Recursively compute the total allocated size of all files under `path`.
    static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return total }
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
            ) else {
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
