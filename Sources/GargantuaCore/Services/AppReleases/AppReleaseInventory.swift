import AppKit
import Foundation

/// Supplies the installed apps the App Updater checks.
public protocol AppReleaseInventoryProviding: Sendable {
    func installedApps() async -> [InstalledApp]
    /// One bundle re-read from disk, or nil when it's gone, unreadable, or
    /// an app the updater doesn't track.
    func installedApp(at url: URL) async -> InstalledApp?
}

/// Reads installed apps from Info.plist and filesystem attributes only.
public struct DefaultAppReleaseInventory: AppReleaseInventoryProviding {
    private let enumerator: any AppBundleEnumerating
    /// Reads a bundle's Team ID from its signature, without validating it.
    private let teamIDReader: @Sendable (URL) -> String?
    private let excludedBundleIDs: Set<String>
    private let isUpdatableLocation: @Sendable (URL) -> Bool

    public init(
        enumerator: any AppBundleEnumerating = DefaultAppBundleEnumerator(),
        teamIDReader: @escaping @Sendable (URL) -> String? = { StrictAppReleaseCodeSigner.teamIdentifier(ofBundle: $0) },
        excludedBundleIDs: Set<String> = Self.defaultExcludedBundleIDs,
        isUpdatableLocation: @escaping @Sendable (URL) -> Bool = { DefaultAppReleaseInventory.isUpdatableLocation($0) }
    ) {
        self.enumerator = enumerator
        self.teamIDReader = teamIDReader
        self.excludedBundleIDs = excludedBundleIDs
        self.isUpdatableLocation = isUpdatableLocation
    }

    /// Gargantua updates itself through Sparkle.
    public static var defaultExcludedBundleIDs: Set<String> {
        var ids: Set<String> = ["com.inceptyon.gargantua"]
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    public func installedApps() async -> [InstalledApp] {
        // System apps are never tracked, so they are dropped before any is read.
        let urls = enumerator.enumerateBundles().filter { isUpdatableLocation($0) && !Self.isSystemPath($0) }
        let running = await Self.runningBundleIDs()
        let reader = teamIDReader
        let read = await boundedMap(urls) { Self.readApp(at: $0, running: running, teamIDReader: reader) }

        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for app in read.compactMap({ $0 }) where isTracked(app) && seen.insert(app.bundleID).inserted {
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func installedApp(at url: URL) async -> InstalledApp? {
        guard isUpdatableLocation(url), !Self.isSystemPath(url) else { return nil }
        let running = await Self.runningBundleIDs()
        guard let app = Self.readApp(at: url, running: running, teamIDReader: teamIDReader),
              isTracked(app)
        else { return nil }
        return app
    }

    /// Helpers nested in other bundles and private tool bundles aren't the user's apps and can't be
    /// updated in place; translocated and mounted-image copies are read-only.
    public static func isUpdatableLocation(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let parts = path.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: { $0.hasSuffix(".app") }) { return false }
        // Judge hidden folders only below home, so a hidden component in home itself doesn't hide every app.
        let belowHome = path.hasPrefix(homePath + "/") ? path.dropFirst(homePath.count + 1) : Substring(path)
        if belowHome.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        if path.hasPrefix("/System/Applications/") { return true }
        let homeLibrary = homePath + "/Library/"
        let blocked = ["/Library/", "/System/", "/private/", "/Volumes/", "/usr/", "/opt/", "/tmp/", "/var/", homeLibrary]
        return !blocked.contains { path.hasPrefix($0) }
    }

    private func isTracked(_ app: InstalledApp) -> Bool {
        !app.isSystem && !excludedBundleIDs.contains(app.bundleID)
    }

    private static func isSystemPath(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("/System/")
    }

    private static func runningBundleIDs() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    }

    // MARK: - Reading

    static func readApp(
        at url: URL,
        running: Set<String>,
        teamIDReader: @Sendable (URL) -> String?
    ) -> InstalledApp? {
        guard let plist = AppBundleFiles.infoPlist(ofBundle: url),
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }

        func string(_ key: String) -> String? {
            (plist[key] as? String)?.trimmedNonEmpty
        }

        let name = string("CFBundleDisplayName") ?? string("CFBundleName")
            ?? url.deletingPathExtension().lastPathComponent
        let version = AppReleaseVersion(plist: plist)
        let fileManager = FileManager.default

        return InstalledApp(
            bundleID: bundleID,
            name: name,
            url: url,
            shortVersion: version.short,
            buildVersion: version.build,
            teamID: teamIDReader(url),
            sparkleFeedURL: string("SUFeedURL").flatMap(URL.init(string:))?.httpsOnly,
            sparklePublicEDKey: string("SUPublicEDKey"),
            minimumSystemVersion: string("LSMinimumSystemVersion"),
            isMAS: fileManager.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            isSystem: isSystemPath(url),
            isRootOwned: isRootOwned(url, fileManager: fileManager),
            isRunning: running.contains(bundleID)
        )
    }

    /// Replacing a bundle needs write access to the bundle and its parent.
    private static func isRootOwned(_ url: URL, fileManager: FileManager) -> Bool {
        let owner = (try? fileManager.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber)?.intValue
        if owner == 0 { return true }
        let parent = url.deletingLastPathComponent().path
        return !fileManager.isWritableFile(atPath: url.path) || !fileManager.isWritableFile(atPath: parent)
    }
}
