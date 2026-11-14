import AppKit
import Foundation

/// Supplies the installed apps the App Updater checks.
public protocol AppReleaseInventoryProviding: Sendable {
    func installedApps() async -> [InstalledApp]
}

/// Reads installed apps from Info.plist and filesystem attributes only.
public struct DefaultAppReleaseInventory: AppReleaseInventoryProviding {
    private let enumerator: any AppBundleEnumerating
    private let signatureReader: any CodeSignatureVerifying
    private let excludedBundleIDs: Set<String>

    private static let maxInFlight = 8

    public init(
        enumerator: any AppBundleEnumerating = DefaultAppBundleEnumerator(),
        signatureReader: any CodeSignatureVerifying = DefaultCodeSignatureVerifier(includeNotarization: false),
        excludedBundleIDs: Set<String> = Self.defaultExcludedBundleIDs
    ) {
        self.enumerator = enumerator
        self.signatureReader = signatureReader
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// Gargantua updates itself through Sparkle.
    public static var defaultExcludedBundleIDs: Set<String> {
        var ids: Set<String> = ["com.inceptyon.gargantua"]
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    public func installedApps() async -> [InstalledApp] {
        let urls = enumerator.enumerateBundles()
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let reader = signatureReader

        var results = [InstalledApp?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, InstalledApp?).self) { group in
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask { (index, Self.readApp(at: url, running: running, signatureReader: reader)) }
            }
            for _ in 0..<Self.maxInFlight { enqueue() }
            while let (index, app) = await group.next() {
                results[index] = app
                enqueue()
            }
        }

        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for app in results.compactMap({ $0 }) {
            guard !app.isSystem, !excludedBundleIDs.contains(app.bundleID),
                  seen.insert(app.bundleID).inserted else { continue }
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Reading

    static func readApp(
        at url: URL,
        running: Set<String>,
        signatureReader: any CodeSignatureVerifying
    ) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        // Not `Bundle(url:)`: Foundation caches instances process-wide, so a
        // re-check after an install would read the old Info.plist.
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }

        func string(_ key: String) -> String? {
            guard let value = plist[key] as? String, !value.isEmpty else { return nil }
            return value
        }

        let name = string("CFBundleDisplayName") ?? string("CFBundleName")
            ?? url.deletingPathExtension().lastPathComponent
        let feedURL = string("SUFeedURL")
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        let fileManager = FileManager.default
        let path = url.standardizedFileURL.path

        return InstalledApp(
            bundleID: bundleID,
            name: name,
            url: url,
            shortVersion: string("CFBundleShortVersionString"),
            buildVersion: string("CFBundleVersion"),
            teamID: signatureReader.verify(bundleURL: url).teamIdentifier,
            sparkleFeedURL: feedURL,
            sparklePublicEDKey: string("SUPublicEDKey"),
            minimumSystemVersion: string("LSMinimumSystemVersion"),
            isMAS: fileManager.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            isSystem: path.hasPrefix("/System/"),
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

/// Tokens of casks Homebrew has installed, from the Caskroom directories.
public struct HomebrewCaskroomProbe: Sendable {
    private let prefixes: [String]

    public init(prefixes: [String] = ["/opt/homebrew", "/usr/local"]) {
        self.prefixes = prefixes
    }

    public func installedTokens() -> Set<String> {
        var tokens = Set<String>()
        for prefix in prefixes {
            let root = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                tokens.insert(entry.lastPathComponent)
            }
        }
        return tokens
    }
}
