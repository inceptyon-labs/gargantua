import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "LaunchdItemIndex")

/// Enumerates `launchd` plists across the conventional source directories and
/// returns deduplicated `LaunchdItem`s.
public protocol LaunchdItemIndexing: Sendable {
    func enumerate() -> [LaunchdItem]
}

/// Default index that walks:
///   - `~/Library/LaunchAgents/`
///   - `/Library/LaunchAgents/`
///   - `/Library/LaunchDaemons/`
///   - `/Library/StartupItems/` (legacy)
///
/// Items are deduped by `(domain, label, plistPath)`. The same Label can
/// legitimately exist in user and system domains; including both in the dedupe
/// key preserves them as distinct entities.
public struct DefaultLaunchdItemIndex: LaunchdItemIndexing {
    private let parser: any LaunchdPlistParsing
    nonisolated(unsafe) private let fileManager: FileManager
    private let userAgentsURL: URL
    private let systemAgentsURL: URL
    private let systemDaemonsURL: URL
    private let startupItemsURL: URL

    public init(
        parser: any LaunchdPlistParsing = DefaultLaunchdPlistParser(),
        fileManager: FileManager = .default,
        userAgentsURL: URL? = nil,
        systemAgentsURL: URL = URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
        systemDaemonsURL: URL = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
        startupItemsURL: URL = URL(fileURLWithPath: "/Library/StartupItems", isDirectory: true)
    ) {
        self.parser = parser
        self.fileManager = fileManager
        self.userAgentsURL = userAgentsURL ?? fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.systemAgentsURL = systemAgentsURL
        self.systemDaemonsURL = systemDaemonsURL
        self.startupItemsURL = startupItemsURL
    }

    public func enumerate() -> [LaunchdItem] {
        let sources: [(LaunchdDomain, URL)] = [
            (.userAgent, userAgentsURL),
            (.systemAgent, systemAgentsURL),
            (.systemDaemon, systemDaemonsURL),
            (.startupItem, startupItemsURL),
        ]

        var seen: Set<DedupeKey> = []
        var items: [LaunchdItem] = []

        for (domain, root) in sources {
            for plistURL in plistURLs(under: root, domain: domain) {
                let item = makeItem(domain: domain, plistURL: plistURL)
                let key = DedupeKey(
                    domain: domain,
                    label: item.plist?.label ?? "",
                    plistPath: item.plistPath
                )
                if seen.insert(key).inserted {
                    items.append(item)
                }
            }
        }

        return items
    }

    // MARK: - Enumeration

    /// Returns `.plist` files directly inside `root`. The Launch{Agents,Daemons}
    /// directories are flat by macOS convention — surfacing plists from
    /// nested subdirectories there could mislead users into thinking launchd
    /// auto-loads them. `StartupItems` is the legacy exception: each entry is
    /// a directory containing a `StartupParameters.plist`, so we descend one
    /// level only for that domain.
    private func plistURLs(under root: URL, domain: LaunchdDomain) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard domain == .startupItem else { continue }
                if let nested = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    results.append(contentsOf: nested.filter { $0.pathExtension == "plist" })
                }
            } else if url.pathExtension == "plist" {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private func makeItem(domain: LaunchdDomain, plistURL: URL) -> LaunchdItem {
        do {
            let plist = try parser.parse(plistURL: plistURL)
            return LaunchdItem(
                domain: domain,
                plistPath: plistURL.path,
                plist: plist,
                parseError: nil
            )
        } catch {
            logger.debug("Failed to parse \(plistURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return LaunchdItem(
                domain: domain,
                plistPath: plistURL.path,
                plist: nil,
                parseError: String(describing: error)
            )
        }
    }

    private struct DedupeKey: Hashable {
        let domain: LaunchdDomain
        let label: String
        let plistPath: String
    }
}
