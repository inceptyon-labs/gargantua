import Foundation
import Testing
@testable import GargantuaCore

@Suite("PrivilegedBackgroundItemValidator")
struct PrivilegedBackgroundItemValidatorTests {

    /// Build a stub `FileSystem` that knows about a small set of paths and
    /// the `Label` each on-disk plist carries. The default
    /// `plistLabel` returns the request's label (i.e. the in-plist label
    /// matches), so the label-binding check passes unless a test overrides it.
    static func fileSystem(
        existing: Set<String> = [],
        symlinks: [String: String] = [:],
        plistLabels: [String: String] = [:],
        defaultPlistLabel: ((String) -> String?)? = nil
    ) -> PrivilegedBackgroundItemValidator.FileSystem {
        let existing = existing
        let symlinks = symlinks
        let plistLabels = plistLabels
        // The library defines plistLabel as @Sendable; closures captured here
        // are only called from synchronous code paths inside the validator,
        // so the explicit @Sendable on parameter conversion is safe.
        let resolver: @Sendable (String) -> String? = { path in
            if let provided = plistLabels[path] { return provided }
            if let resolver = defaultPlistLabel { return resolver(path) }
            // Default: derive the label from the filename so most tests
            // can stay terse (`com.foo.plist` => `com.foo`).
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "plist" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        return PrivilegedBackgroundItemValidator.FileSystem(
            fileExists: { path, isDir in
                if existing.contains(path) {
                    isDir?.pointee = false
                    return true
                }
                return false
            },
            resolvedSymlinkPath: { path in
                symlinks[path] ?? path
            },
            plistLabel: resolver
        )
    }
}
