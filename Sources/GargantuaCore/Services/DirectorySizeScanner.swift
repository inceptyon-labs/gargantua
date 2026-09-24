import Darwin
import Foundation
import os

/// Classification of a single directory child, shared by `streamChildren` and
/// `scanChildrenSync` so the UF_HIDDEN/dotfile, mount-root, and permission
/// logic lives in one place.
enum ChildKind {
    case skip
    case file(size: Int64)
    case mountRoot(isNetwork: Bool)
    case readableDirectory
    case unreadableDirectory
}

/// Dot-prefixed names stay hidden; UF_HIDDEN system folders (e.g. /opt, /usr,
/// /Volumes) are not filtered by name and are classified normally.
func classifyChild(
    _ child: URL,
    fm: FileManager,
    mountRootCheck: @Sendable (URL) -> (isMountRoot: Bool, isNetwork: Bool)
) -> ChildKind {
    if child.lastPathComponent.hasPrefix(".") {
        return .skip
    }
    if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
        return .skip
    }
    let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    guard isDirectory else {
        let fileSize = (try? child.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey]
        ))?.totalFileAllocatedSize ?? 0
        return .file(size: Int64(fileSize))
    }
    let mountInfo = mountRootCheck(child)
    if mountInfo.isMountRoot {
        return .mountRoot(isNetwork: mountInfo.isNetwork)
    }
    guard fm.isReadableFile(atPath: child.path) else {
        return .unreadableDirectory
    }
    return .readableDirectory
}

/// Identifies a file by (device, inode) so `directorySize`'s explorer accounting can count a
/// hard-linked file's allocated size only the first time that pair is seen in a given walk.
struct InodeKey: Hashable {
    let device: Int32
    let inode: UInt64

    init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        self.device = st.st_dev
        self.inode = st.st_ino
    }
}

/// Reads the APFS "private size" of `path` — the portion of its content not shared with any
/// clone — via `getattrlist`'s common-extended attribute group. Returns `nil` on any failure
/// (non-APFS volume, permission, etc.), in which case the caller adds nothing to shared bytes.
///
/// Buffer layout the kernel writes back: a `UInt32` length, then the returned `attribute_set_t`,
/// then the `off_t` private size. Decoded with `loadUnaligned` rather than a matching Swift
/// struct since the C struct's packing isn't a Swift layout guarantee.
func privateCloneSize(atPath path: String) -> Int64? {
    var attrList = attrlist()
    attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    attrList.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

    let bufferSize = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size + MemoryLayout<off_t>.size
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    let result = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
        getattrlist(path, &attrList, rawBuffer.baseAddress, rawBuffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
    }
    guard result == 0 else { return nil }

    let privateSizeOffset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
    let privateSize: off_t = buffer.withUnsafeBytes { rawBuffer in
        rawBuffer.loadUnaligned(fromByteOffset: privateSizeOffset, as: off_t.self)
    }
    return Int64(privateSize)
}

/// Applies the same hard-link/clone accounting `directorySize(explorerAccounting: true)` uses,
/// scoped to the loose top-level files folded into the "(Files)" aggregate row. `url`'s resource
/// values are already cached from the directory listing's `includingPropertiesForKeys`, so these
/// lookups don't cost another directory read — only `lstat`/`getattrlist` for the two accounting
/// checks themselves.
func looseFileAccounting(
    for url: URL,
    allocated: Int64,
    seenInodes: inout Set<InodeKey>
) -> (countedSize: Int64, sharedCloneBytes: Int64) {
    let values = try? url.resourceValues(forKeys: [.linkCountKey, .mayShareFileContentKey])

    var countedSize = allocated
    if let linkCount = values?.linkCount, linkCount > 1, let key = InodeKey(path: url.path) {
        countedSize = seenInodes.insert(key).inserted ? allocated : 0
    }

    var sharedCloneBytes: Int64 = 0
    if values?.mayShareFileContent == true, let privateSize = privateCloneSize(atPath: url.path) {
        sharedCloneBytes = max(allocated - privateSize, 0)
    }

    return (countedSize, sharedCloneBytes)
}

/// Tracks, in a Sendable-safe way, whether the enumerator in `DirectorySizeScanner.directorySize`
/// hit any unreadable entry.
final class UnreadableEntryFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    func mark() {
        flag.withLock { $0 = true }
    }

    var wasHit: Bool {
        flag.withLock { $0 }
    }
}

/// Scans directory sizes using FileManager for the Disk Explorer.
///
/// Returns immediate children of a directory with their total sizes (recursively computed).
/// Handles permission-denied paths gracefully by marking them in the result.
public enum DirectorySizeScanner: Sendable {
    struct DirectorySizeResult: Sendable, Equatable {
        let totalSize: Int64
        let isPartial: Bool
        var sharedCloneBytes: Int64 = 0
    }

    public static let defaultDirectorySizeTimeout: Duration = .seconds(15)

    /// Maximum number of concurrent `directorySize` computations.
    ///
    /// Capped to avoid saturating the filesystem with parallel recursive walks while
    /// still letting SSD random-I/O parallelism help sizing proceed visibly faster.
    private static let sizingConcurrency = 4

    /// Identifies children that are separate volume mount points (e.g. `/Volumes/X`,
    /// `/System/Volumes/Data`, `/dev`) via `.isVolumeKey`, and whether that volume is
    /// remote via `.volumeIsLocalKey`. Injectable for testing.
    static let defaultMountRootCheck: @Sendable (URL) -> (isMountRoot: Bool, isNetwork: Bool) = { url in
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeIsLocalKey])
        return (values?.isVolume == true, values?.volumeIsLocal == false)
    }

    /// Scan the immediate children of `directoryPath`, returning each child directory
    /// with its recursively computed total size, sorted largest first.
    ///
    /// Files at the top level are aggregated into a single "(Files)" entry.
    /// Permission-denied children are included with `isPermissionDenied = true` and size 0.
    public static func scanChildren(
        of directoryPath: String,
        directorySizeTimeout: Duration? = defaultDirectorySizeTimeout
    ) async -> [DirectoryItem] {
        await scanChildren(
            of: directoryPath,
            directorySizeTimeout: directorySizeTimeout,
            mountRootCheck: defaultMountRootCheck
        )
    }

    /// `mountRootCheck`-injectable overload for testing. Mount-root rows carry
    /// size 0 and sort after sized rows through the ordinary size comparison below.
    static func scanChildren(
        of directoryPath: String,
        directorySizeTimeout: Duration?,
        mountRootCheck: @escaping @Sendable (URL) -> (isMountRoot: Bool, isNetwork: Bool)
    ) async -> [DirectoryItem] {
        var items: [DirectoryItem] = []
        for await item in streamChildren(
            of: directoryPath,
            directorySizeTimeout: directorySizeTimeout,
            mountRootCheck: mountRootCheck
        ) where !item.isSizing {
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
    /// 2. One `isMountRoot: true` row per child that is a separate volume mount point,
    ///    emitted immediately with size 0 (never sized, no follow-up event).
    /// 3. One permission-denied row per unreadable subdirectory (no follow-up event).
    /// 4. One "(Files)" aggregate row if loose files exist at this level.
    /// 5. One `isSizing: false` row per previously-placeheld directory, replacing it by id
    ///    once its recursive size is known. Emitted in size-computation-finish order.
    ///
    /// The stream honors cancellation: if the consuming task is cancelled (typically
    /// because `DiskExplorerView`'s `.task(id:)` restarted with a new path), in-flight
    /// sizing tasks stop enumerating on their next iteration and the stream terminates.
    public static func streamChildren(
        of directoryPath: String,
        directorySizeTimeout: Duration? = defaultDirectorySizeTimeout
    ) -> AsyncStream<DirectoryItem> {
        streamChildren(
            of: directoryPath,
            directorySizeTimeout: directorySizeTimeout,
            mountRootCheck: defaultMountRootCheck
        )
    }

    /// `mountRootCheck`-injectable overload for testing.
    static func streamChildren(
        of directoryPath: String,
        directorySizeTimeout: Duration?,
        mountRootCheck: @escaping @Sendable (URL) -> (isMountRoot: Bool, isNetwork: Bool)
    ) -> AsyncStream<DirectoryItem> {
        AsyncStream { continuation in
            let task = Task.detached { [continuation, mountRootCheck] in
                let fm = FileManager.default
                let url = URL(fileURLWithPath: directoryPath)

                // Dot-prefixed names stay hidden; UF_HIDDEN system folders (e.g. /opt,
                // /usr, /Volumes) are not filtered by name and are listed.
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
                    continuation.finish()
                    return
                }

                var subdirectoriesToSize: [URL] = []
                var topLevelFilesSize: Int64 = 0
                var topLevelSharedCloneBytes: Int64 = 0
                var topLevelSeenInodes: Set<InodeKey> = []

                for child in contents {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    switch classifyChild(child, fm: fm, mountRootCheck: mountRootCheck) {
                    case .skip:
                        continue
                    case .file(let size):
                        let accounting = looseFileAccounting(for: child, allocated: size, seenInodes: &topLevelSeenInodes)
                        topLevelFilesSize += accounting.countedSize
                        topLevelSharedCloneBytes += accounting.sharedCloneBytes
                    case .mountRoot(let isNetwork):
                        // A separate volume: list it, but don't recursively size it
                        // until the user drills in.
                        continuation.yield(DirectoryItem(
                            name: child.lastPathComponent,
                            path: child.path,
                            size: 0,
                            isMountRoot: true,
                            isNetworkVolume: isNetwork
                        ))
                    case .readableDirectory:
                        continuation.yield(DirectoryItem(
                            name: child.lastPathComponent,
                            path: child.path,
                            size: 0,
                            isSizing: true
                        ))
                        subdirectoriesToSize.append(child)
                    case .unreadableDirectory:
                        continuation.yield(DirectoryItem(
                            name: child.lastPathComponent,
                            path: child.path,
                            size: 0,
                            isPermissionDenied: true
                        ))
                    }
                }

                if topLevelFilesSize > 0 {
                    continuation.yield(DirectoryItem(
                        name: "(Files)",
                        path: directoryPath + "/(files)",
                        size: topLevelFilesSize,
                        isFilesAggregate: true,
                        sharedCloneBytes: topLevelSharedCloneBytes
                    ))
                }

                await sizeDirectoriesStreaming(
                    subdirectoriesToSize,
                    maxConcurrent: sizingConcurrency,
                    directorySizeTimeout: directorySizeTimeout,
                    yield: { continuation.yield($0) }
                )

                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
