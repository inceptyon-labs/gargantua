import AppKit
import Foundation

/// Abstraction over bundle discovery so the scanner can be unit-tested with stubs.
public protocol AppBundleEnumerating: Sendable {
    /// Return every `.app` bundle URL known to the system, deduplicated by
    /// standardised path.
    func enumerateBundles() -> [URL]
}

/// Default enumerator: walks the configured search roots and augments the result
/// with running-app bundle URLs from `NSWorkspace`.
///
/// Launch Services no longer exposes a non-deprecated "list every registered app"
/// API on modern macOS. Walking `/Applications` and `~/Applications` covers the
/// canonical install locations, and the running-apps pass picks up bundles launched
/// from unusual locations (e.g., `/opt`, `~/Downloads`).
public struct DefaultAppBundleEnumerator: AppBundleEnumerating {
    public let searchRoots: [URL]
    public let includeRunningApps: Bool

    public init(
        searchRoots: [URL]? = nil,
        includeRunningApps: Bool = true
    ) {
        self.searchRoots = searchRoots ?? Self.defaultSearchRoots()
        self.includeRunningApps = includeRunningApps
    }

    /// `/Applications`, `~/Applications`, and `/System/Applications`. The system
    /// root is included so the picker's "Show system apps" toggle has something
    /// meaningful to reveal — apps under `/System/Applications` are flagged
    /// `isSystemApp = true` by `DefaultAppScanner` and stay hidden until the
    /// user opts in. Without this root the toggle only filters a handful of
    /// background services picked up via `NSWorkspace.runningApplications`,
    /// which to the user looks like the toggle does nothing.
    public static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent("Applications", isDirectory: true))
        roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        return roots
    }

    public func enumerateBundles() -> [URL] {
        var seenPaths = Set<String>()
        var results: [URL] = []

        for root in searchRoots {
            for url in enumerate(root: root) {
                let key = url.standardizedFileURL.path
                if seenPaths.insert(key).inserted {
                    results.append(url)
                }
            }
        }

        if includeRunningApps {
            for app in NSWorkspace.shared.runningApplications {
                guard let bundleURL = app.bundleURL,
                      bundleURL.pathExtension == "app"
                else { continue }
                let key = bundleURL.standardizedFileURL.path
                if seenPaths.insert(key).inserted {
                    results.append(bundleURL)
                }
            }
        }
        return results
    }

    private func enumerate(root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            )
        else {
            return []
        }
        var apps: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if item.pathExtension == "app" {
                apps.append(item)
                enumerator.skipDescendants()
            }
        }
        return apps
    }
}
