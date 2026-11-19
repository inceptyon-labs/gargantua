import Foundation

/// A cask Homebrew has installed, read from its Caskroom folder.
public struct HomebrewInstalledCask: Sendable, Equatable {
    public let token: String
    /// Installed `.app` names, after any `target` rename. Nil when the cask's
    /// metadata couldn't be read, so which app it installed is unknown.
    public let appNames: [String]?
    /// Bundle IDs from `uninstall: quit:`; a trailing `.*` is a prefix wildcard.
    public let quitBundleIDs: [String]
    /// The tap from the install receipt's `source`; nil on older receipts.
    public let tap: String?

    public init(token: String, appNames: [String]? = nil, quitBundleIDs: [String] = [], tap: String? = nil) {
        self.token = token
        self.tap = tap
        self.appNames = appNames
        self.quitBundleIDs = quitBundleIDs
    }
}

/// Casks Homebrew has installed, from the local Caskroom. This covers casks
/// from any tap, and works when the public index is unreachable.
public struct HomebrewCaskroomProbe: Sendable {
    static let maxMetadataBytes = 4 * 1_048_576
    private let prefixes: [String]

    public init(prefixes: [String] = ["/opt/homebrew", "/usr/local"]) {
        self.prefixes = prefixes
    }

    public func installedCasks() -> [HomebrewInstalledCask] {
        prefixes.flatMap { prefix in
            Self.subdirectories(of: URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom", isDirectory: true))
                .map(Self.readCask(at:))
        }
    }

    /// Current Homebrew keeps the cask's artifacts in the install receipt's
    /// `uninstall_artifacts` and leaves `Casks/<token>.json` nearly empty;
    /// older versions wrote the whole cask there. Both are read and merged.
    /// A `.rb` cask isn't parseable here and is skipped.
    static func readCask(at directory: URL) -> HomebrewInstalledCask {
        let token = directory.lastPathComponent
        let metadata = directory.appendingPathComponent(".metadata", isDirectory: true)
        var found: [HomebrewCaskArtifacts] = []
        let receipt = readJSON(metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        if let list = receipt?["uninstall_artifacts"] as? [Any] {
            found.append(HomebrewCaskArtifacts(list))
        }
        if let newest = newestMetadataDirectory(in: metadata),
           let list = readJSON(newest.appendingPathComponent("Casks/\(token).json"))?["artifacts"] as? [Any] {
            found.append(HomebrewCaskArtifacts(list))
        }
        return HomebrewInstalledCask(
            token: token,
            appNames: found.isEmpty ? nil : found.flatMap(\.appNames),
            quitBundleIDs: found.flatMap(\.quitBundleIDs),
            tap: (receipt?["source"] as? [String: Any])?["tap"] as? String
        )
    }

    /// `.metadata/<version>/<timestamp>` with the latest timestamp. Homebrew
    /// writes timestamps as fixed-width `YYYYMMDDhhmmss.sss`, so they sort as text.
    static func newestMetadataDirectory(in metadata: URL) -> URL? {
        subdirectories(of: metadata)
            .flatMap(subdirectories(of:))
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxMetadataBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Which installed cask owns an app, so its updates go through brew.
///
/// Errs toward brew: calling an app brew-managed only limits it to a link or
/// `brew upgrade`, while missing one would replace it behind brew's back.
public struct HomebrewCaskOwnership: Sendable {
    private let casks: [HomebrewInstalledCask]

    public init(casks: [HomebrewInstalledCask]) {
        self.casks = casks
    }

    /// - Parameter indexToken: The cask the public index matched to the app.
    ///   It owns the app when that cask is installed, and wins over the
    ///   Caskroom's own matches.
    /// - Returns: The owning cask's token, or nil when brew didn't install
    ///   the app.
    public func owner(of app: InstalledApp, indexToken: String?) -> String? {
        if let indexToken, casks.contains(where: { $0.token == indexToken }) { return indexToken }
        let filename = app.url.lastPathComponent.lowercased()
        return casks.filter { cask in
            guard let appNames = cask.appNames else {
                // Unknown contents: a token that reads as the app's name counts.
                return cask.token.lowercased() == Self.tokenGuess(forAppNamed: filename)
            }
            return appNames.contains { $0.lowercased() == filename }
                && (cask.quitBundleIDs.isEmpty || Self.quitListAdmits(cask.quitBundleIDs, bundleID: app.bundleID))
        }
        .map(\.token)
        .min()
    }

    /// Whether the public index's entry describes the owning cask: it must be
    /// the index's match and installed from the public tap (or an unknown one) in every copy.
    public func publicIndexDescribes(owner: String, indexToken: String?) -> Bool {
        guard owner == indexToken else { return false }
        return casks.filter { $0.token == owner }.allSatisfy { cask in
            let tap = cask.tap?.lowercased()
            return tap == nil || tap == "homebrew/cask"
        }
    }

    /// A quit list naming only same-vendor helpers doesn't contradict the app
    /// being the cask's; only a list made entirely of other vendors' IDs does.
    static func quitListAdmits(_ quitIDs: [String], bundleID: String) -> Bool {
        if HomebrewCaskMatcher.quits(quitIDs, bundleID: bundleID) { return true }
        guard let vendor = vendorPrefix(of: bundleID) else { return false }
        return quitIDs.contains { vendorPrefix(of: $0) == vendor }
    }

    /// The first two components of a bundle ID, lowercased (`org.pqrs`); nil
    /// below three components, where the vendor can't be told from the app.
    static func vendorPrefix(of bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    /// `foo bar.app` → `foo-bar`, Homebrew's usual token for an app.
    static func tokenGuess(forAppNamed filename: String) -> String {
        let base = filename.lowercased().hasSuffix(".app") ? String(filename.dropLast(4)) : filename
        return base.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
