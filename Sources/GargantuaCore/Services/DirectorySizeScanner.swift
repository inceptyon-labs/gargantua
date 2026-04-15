import Foundation

/// Scans directory sizes using FileManager for the Disk Explorer.
///
/// Returns immediate children of a directory with their total sizes (recursively computed).
/// Handles permission-denied paths gracefully by marking them in the result.
public enum DirectorySizeScanner: Sendable {

    /// Scan the immediate children of `directoryPath`, returning each child directory
    /// with its recursively computed total size, sorted largest first.
    ///
    /// Files at the top level are aggregated into a single "(Files)" entry.
    /// Permission-denied children are included with `isPermissionDenied = true` and size 0.
    public static func scanChildren(of directoryPath: String) async -> [DirectoryItem] {
        await Task.detached {
            scanChildrenSync(of: directoryPath)
        }.value
    }

    // MARK: - Internal

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
            // Skip symbolic links to avoid cycles
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }

            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                // Check if we can read inside
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

        // Aggregate loose files
        if topLevelFilesSize > 0 {
            items.append(DirectoryItem(
                name: "(Files)",
                path: directoryPath + "/(files)",
                size: topLevelFilesSize
            ))
        }

        // Sort by size descending, permission-denied last
        items.sort { lhs, rhs in
            if lhs.isPermissionDenied != rhs.isPermissionDenied {
                return !lhs.isPermissionDenied
            }
            return lhs.size > rhs.size
        }

        return items
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
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
            ) else {
                continue
            }
            // Skip symlinks
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
