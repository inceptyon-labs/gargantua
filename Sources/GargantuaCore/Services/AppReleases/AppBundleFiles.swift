import Darwin
import Foundation

/// Reads app bundles on disk without following links, for the inventory,
/// the verifier and the installer.
enum AppBundleFiles {
    static let maxInfoPlistBytes = 4 * 1_048_576

    /// Reads `Contents/Info.plist` with `PropertyListSerialization`, never
    /// `Bundle(url:)` (Foundation caches Bundle instances process-wide, so a
    /// re-read after an install would see the old plist). `Contents` must be
    /// a real directory and the plist a regular file no larger than
    /// `maxInfoPlistBytes`; neither is followed through a symlink.
    static func infoPlist(ofBundle bundle: URL) -> [String: Any]? {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard fileType(atPath: contents.path) == S_IFDIR else { return nil }
        let path = contents.appendingPathComponent("Info.plist").path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maxInfoPlistBytes,
              let data = try? handle.readToEnd()
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Version from a bundle's Info.plist on disk, or nil when unreadable.
    static func bundleVersion(at bundle: URL) -> AppReleaseVersion? {
        infoPlist(ofBundle: bundle).map(AppReleaseVersion.init(plist:))
    }

    /// `lstat` file type bits, or nil when the path can't be stat'ed.
    static func fileType(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
