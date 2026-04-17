import Foundation

/// A directory entry for the Disk Explorer, representing a path with its total size.
///
/// Children are loaded on demand when the user expands a row.
/// Permission-denied directories are represented with `isPermissionDenied = true`
/// and zero size.
public struct DirectoryItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let size: Int64
    public let isPermissionDenied: Bool

    /// `true` while the directory's recursive size is still being computed
    /// (used by streaming scans to render a placeholder row with a spinner).
    public let isSizing: Bool

    /// `true` when this row represents the synthetic "(Files)" aggregate of
    /// loose files at the current directory level rather than a real child
    /// directory. Disambiguates `id` so an actual subdirectory literally named
    /// `(files)` does not collide with the aggregate.
    public let isFilesAggregate: Bool

    /// Child items, loaded on demand. `nil` means not yet loaded.
    public var children: [DirectoryItem]?

    public init(
        name: String,
        path: String,
        size: Int64,
        isPermissionDenied: Bool = false,
        isSizing: Bool = false,
        isFilesAggregate: Bool = false,
        children: [DirectoryItem]? = nil
    ) {
        self.id = isFilesAggregate ? "\(path)#filesAggregate" : path
        self.name = name
        self.path = path
        self.size = size
        self.isPermissionDenied = isPermissionDenied
        self.isSizing = isSizing
        self.isFilesAggregate = isFilesAggregate
        self.children = children
    }
}
