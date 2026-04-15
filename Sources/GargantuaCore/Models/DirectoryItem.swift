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

    /// Child items, loaded on demand. `nil` means not yet loaded.
    public var children: [DirectoryItem]?

    public init(
        name: String,
        path: String,
        size: Int64,
        isPermissionDenied: Bool = false,
        children: [DirectoryItem]? = nil
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.size = size
        self.isPermissionDenied = isPermissionDenied
        self.children = children
    }
}
