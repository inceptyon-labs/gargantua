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

    /// `true` when `size` is a lower-bound total because recursive sizing
    /// stopped early, usually after hitting a wall-clock timeout.
    public let isPartial: Bool

    /// `true` while the directory's recursive size is still being computed
    /// (used by streaming scans to render a placeholder row with a spinner).
    public let isSizing: Bool

    /// `true` when this row represents the synthetic "(Files)" aggregate of
    /// loose files at the current directory level rather than a real child
    /// directory. Disambiguates `id` so an actual subdirectory literally named
    /// `(files)` does not collide with the aggregate.
    public let isFilesAggregate: Bool

    /// `true` when this row represents the synthetic "Others" treemap tile
    /// that bundles directories too small to render as their own visible
    /// rectangle. Not drillable; surfaced only in the treemap view.
    public let isOthersAggregate: Bool

    /// Child items, loaded on demand. `nil` means not yet loaded.
    public var children: [DirectoryItem]?

    public init(
        name: String,
        path: String,
        size: Int64,
        isPermissionDenied: Bool = false,
        isPartial: Bool = false,
        isSizing: Bool = false,
        isFilesAggregate: Bool = false,
        isOthersAggregate: Bool = false,
        children: [DirectoryItem]? = nil
    ) {
        if isFilesAggregate {
            self.id = "\(path)#filesAggregate"
        } else if isOthersAggregate {
            self.id = "\(path)#othersAggregate"
        } else {
            self.id = path
        }
        self.name = name
        self.path = path
        self.size = size
        self.isPermissionDenied = isPermissionDenied
        self.isPartial = isPartial
        self.isSizing = isSizing
        self.isFilesAggregate = isFilesAggregate
        self.isOthersAggregate = isOthersAggregate
        self.children = children
    }
}
