import Foundation

/// Checks macOS TCC permissions required by Gargantua.
public enum PermissionChecker: Sendable {
    /// Whether the app has Full Disk Access.
    ///
    /// Probes a TCC-protected path that is only readable with FDA granted.
    /// Returns `false` if the path is unreadable (permission denied) or
    /// if the file doesn't exist (shouldn't happen on a normal macOS install).
    public static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(
            atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
        )
    }
}
