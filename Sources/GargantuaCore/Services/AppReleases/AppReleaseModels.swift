import Foundation

/// An installed third-party app as the App Updater sees it.
///
/// Built by `AppReleaseInventory` from Info.plist and filesystem attributes
/// only. It deliberately skips the size walk and signature validation that
/// `DefaultAppScanner` does for the uninstaller, so a check run stays cheap.
public struct InstalledApp: Sendable, Equatable, Identifiable {
    public var id: String { bundleID }

    public let bundleID: String
    public let name: String
    public let url: URL
    /// `CFBundleShortVersionString`. Settable so the installer can carry the
    /// version on disk now instead of the one seen at check time.
    public internal(set) var shortVersion: String?
    /// `CFBundleVersion`.
    public internal(set) var buildVersion: String?
    /// Developer ID team from the code signature, read without validation.
    public let teamID: String?
    /// `SUFeedURL`, only when it is an https URL.
    public let sparkleFeedURL: URL?
    /// `SUPublicEDKey`, base64.
    public let sparklePublicEDKey: String?
    /// `LSMinimumSystemVersion`.
    public let minimumSystemVersion: String?
    /// `Contents/_MASReceipt/receipt` exists.
    public let isMAS: Bool
    /// Bundle lives under `/System/`.
    public let isSystem: Bool
    /// Bundle is owned by root or not writable by the current user, so an
    /// unprivileged in-place swap cannot work.
    public let isRootOwned: Bool
    public let isRunning: Bool
    /// The vendor updater the app registers with (`KSProductID`), if any.
    public let selfUpdater: AppReleaseSelfUpdater?

    public var version: AppReleaseVersion {
        AppReleaseVersion(short: shortVersion, build: buildVersion)
    }

    public init(
        bundleID: String,
        name: String,
        url: URL,
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        teamID: String? = nil,
        sparkleFeedURL: URL? = nil,
        sparklePublicEDKey: String? = nil,
        minimumSystemVersion: String? = nil,
        isMAS: Bool = false,
        isSystem: Bool = false,
        isRootOwned: Bool = false,
        isRunning: Bool = false,
        selfUpdater: AppReleaseSelfUpdater? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.teamID = teamID
        self.sparkleFeedURL = sparkleFeedURL
        self.sparklePublicEDKey = sparklePublicEDKey
        self.minimumSystemVersion = minimumSystemVersion
        self.isMAS = isMAS
        self.isSystem = isSystem
        self.isRootOwned = isRootOwned
        self.isRunning = isRunning
        self.selfUpdater = selfUpdater
    }
}

/// Google's updater, which installs an app's new versions itself. Found from
/// the app's Keystone registration (`KSProductID`) and the updater's
/// system-wide launch daemon: running as root, it is why such an app is
/// root's, as Chrome is. Other vendors' Keystone forks aren't recognized,
/// since where their updater lives isn't known, so their updates stay ones
/// to act on.
public struct AppReleaseSelfUpdater: Sendable, Equatable {
    public let productID: String

    public init(productID: String) {
        self.productID = productID
    }

    /// Daemons that run Google's system-wide updater: the current one and
    /// the older Keystone. Removing the updater removes them.
    public static let googleSystemDaemons = [
        "/Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist",
        "/Library/LaunchDaemons/com.google.keystone.daemon.plist",
    ]

    /// The updater for `productID`, when it is a Google product, root owns
    /// the bundle, and Google's system-wide updater is installed; otherwise
    /// nil. A bundle that is only unwritable, as on a standard account, is
    /// kept current by an updater that runs for whoever installed it.
    static func google(productID: String?, systemUpdaterInstalled: Bool, ownedByRoot: Bool) -> AppReleaseSelfUpdater? {
        guard systemUpdaterInstalled, ownedByRoot, let productID, productID.lowercased().hasPrefix("com.google.") else {
            return nil
        }
        return AppReleaseSelfUpdater(productID: productID)
    }

    /// A page inside the app that checks for an update right away, when one
    /// is known. Opening it starts that check.
    public var updatePage: URL? {
        productID.lowercased().hasPrefix("com.google.chrome") ? URL(string: "chrome://settings/help") : nil
    }
}

/// Where a release candidate came from. Declaration order is the tie-break
/// order when two sources offer the same version: curated catalog first, then
/// the vendor's own signed feed, then Homebrew.
public enum AppReleaseSourceKind: String, Sendable, Equatable, Codable, CaseIterable {
    case catalog
    case sparkle
    case homebrewCask
    case appStore

    public var label: String {
        switch self {
        case .catalog: "Catalog"
        case .sparkle: "Sparkle"
        case .homebrewCask: "Homebrew"
        case .appStore: "App Store"
        }
    }

    var tieBreakRank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// Container format of a downloadable update.
public enum AppReleasePayloadKind: String, Sendable, Equatable {
    case zip
    case dmg
    case tar
    case pkg
    case unknown

    /// Infers the payload kind from the download URL's path extension, then
    /// from an enclosure MIME type.
    public static func infer(url: URL?, mimeType: String? = nil) -> AppReleasePayloadKind {
        let path = url?.path.lowercased() ?? ""
        if path.hasSuffix(".zip") { return .zip }
        if path.hasSuffix(".dmg") { return .dmg }
        if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") || path.hasSuffix(".tar.xz")
            || path.hasSuffix(".tar.bz2") || path.hasSuffix(".tbz") || path.hasSuffix(".tar") {
            return .tar
        }
        if path.hasSuffix(".pkg") || path.hasSuffix(".mpkg") { return .pkg }
        switch mimeType?.lowercased() {
        case "application/zip", "application/x-zip-compressed": return .zip
        case "application/x-apple-diskimage", "application/x-diskimage": return .dmg
        case "application/x-tar", "application/gzip", "application/x-gzip", "application/x-xz": return .tar
        case "application/x-apple-installer-package", "application/vnd.apple.installer+xml": return .pkg
        default: return .unknown
        }
    }

    /// Whether the in-place install pipeline may try this kind. `.unknown`
    /// is allowed because many cask URLs carry no extension; the stager sniffs
    /// the downloaded bytes and refuses anything that isn't zip, dmg or tar.
    public var isInstallable: Bool {
        switch self {
        case .zip, .dmg, .tar, .unknown: true
        case .pkg: false
        }
    }
}

/// One newer-or-equal release offered by a source for an installed app.
///
/// The fields a curated catalog entry overrides are settable inside the
/// module, so pinning edits a copy instead of rebuilding every field.
public struct AppReleaseCandidate: Sendable, Equatable {
    public internal(set) var source: AppReleaseSourceKind
    public let version: AppReleaseVersion
    /// Human-facing version string, e.g. `2.4.1 (812)`.
    public let displayVersion: String
    public let downloadURL: URL?
    /// Enclosure `length` in bytes, when the source declares it.
    public let expectedLength: Int64?
    /// Sparkle `sparkle:edSignature` (base64 Ed25519) over the download.
    public let edSignature: String?
    /// Lowercase hex SHA-256 of the download; nil when the source has none
    /// (including Homebrew's `no_check`).
    public let sha256: String?
    public let minimumSystemVersion: String?
    public let payloadKind: AppReleasePayloadKind
    /// https only; `init` drops any other scheme, since feeds control it.
    public let releaseNotesURL: URL?
    /// Vendor homepage, App Store page, or release page for link-only rows.
    /// https only, like `releaseNotesURL`.
    public internal(set) var vendorURL: URL?
    /// Homebrew cask token, set when `source == .homebrewCask`.
    public let caskToken: String?
    /// Team ID the new bundle must carry, pinned by a catalog entry.
    public internal(set) var pinnedTeamID: String?
    /// False when a catalog entry marks the app link-only.
    public internal(set) var allowsInPlaceInstall: Bool
    /// The release came from a Sparkle appcast (the app's own or a catalog
    /// feed), so an installed `SUPublicEDKey` requires an EdDSA signature.
    public internal(set) var isSparkleFeed: Bool
    /// How the download is requested; set from the cask for Homebrew releases.
    public let downloadAgent: AppReleaseDownloadAgent

    public var isPrerelease: Bool { version.isPrerelease }

    public init(
        source: AppReleaseSourceKind,
        version: AppReleaseVersion,
        displayVersion: String? = nil,
        downloadURL: URL? = nil,
        expectedLength: Int64? = nil,
        edSignature: String? = nil,
        sha256: String? = nil,
        minimumSystemVersion: String? = nil,
        payloadKind: AppReleasePayloadKind? = nil,
        releaseNotesURL: URL? = nil,
        vendorURL: URL? = nil,
        caskToken: String? = nil,
        pinnedTeamID: String? = nil,
        allowsInPlaceInstall: Bool = true,
        isSparkleFeed: Bool? = nil,
        downloadAgent: AppReleaseDownloadAgent = .updater
    ) {
        self.source = source
        self.version = version
        self.displayVersion = displayVersion ?? version.description
        self.downloadURL = downloadURL
        self.expectedLength = expectedLength
        self.edSignature = edSignature
        self.sha256 = sha256?.lowercased()
        self.minimumSystemVersion = minimumSystemVersion
        self.payloadKind = payloadKind ?? AppReleasePayloadKind.infer(url: downloadURL)
        self.releaseNotesURL = releaseNotesURL?.httpsOnly
        self.vendorURL = vendorURL?.httpsOnly
        self.caskToken = caskToken
        self.pinnedTeamID = pinnedTeamID
        self.allowsInPlaceInstall = allowsInPlaceInstall
        self.isSparkleFeed = isSparkleFeed ?? (source == .sparkle)
        self.downloadAgent = downloadAgent
    }

    /// Whether `skipped`, a stored `displayVersion`, names this release.
    /// Sources word one release differently (Sparkle `2.4.1 (812)`, Homebrew
    /// `2.4.1`), so a skip recorded without a build covers every build of
    /// that version, and one recorded with a build covers a source that
    /// reports none.
    public func matchesSkipped(_ skipped: String) -> Bool {
        if skipped == displayVersion || skipped == version.description { return true }
        guard let short = version.short else { return false }
        return skipped == short || (version.build == nil && skipped.hasPrefix(short + " ("))
    }
}

/// Why an available update can only be opened as a link.
public enum AppReleaseLinkOnlyReason: String, Sendable, Equatable {
    /// The update ships as a .pkg installer, which needs root.
    case packageInstaller
    /// The installed bundle is owned by root or not writable by the user.
    case rootOwned
    /// The installed bundle has no Team ID, so a replacement cannot be pinned.
    case unsigned
    /// A catalog entry marks this app link-only.
    case catalogLinkOnly
    /// The app is managed by Homebrew, but the cask is older than the newest
    /// release; updating outside brew would desync it.
    case brewCaskBehind
    /// The source gave no download URL, or a payload type we can't unpack.
    case noInstallablePayload

    public var explanation: String {
        switch self {
        case .packageInstaller: "Ships as an installer package, which needs an administrator."
        case .rootOwned: "Installed by an administrator; Gargantua won't replace it."
        case .unsigned: "Not signed by a developer, so a replacement can't be verified."
        case .catalogLinkOnly: "The vendor's download needs to be installed by hand."
        case .brewCaskBehind: "Managed by Homebrew, and Homebrew doesn't have this version yet."
        case .noInstallablePayload: "No download Gargantua can verify and install."
        }
    }
}

/// How an available update gets onto the Mac.
public enum AppReleaseInstallStrategy: Sendable, Equatable {
    /// Download, verify, and swap the bundle ourselves.
    case inPlace
    /// `brew upgrade --cask <token>`.
    case brewUpgrade(token: String)
    /// Open the App Store product page.
    case openAppStore(URL)
    /// Show the vendor page; nothing to install from here.
    case linkOnly(URL?, reason: AppReleaseLinkOnlyReason)
    /// The app's own updater installs it, as root; nothing for the user to do.
    case updatesItself(AppReleaseSelfUpdater)

    /// Whether this strategy changes the disk and so needs the license gate.
    public var isDestructive: Bool {
        switch self {
        case .inPlace, .brewUpgrade: true
        case .openAppStore, .linkOnly, .updatesItself: false
        }
    }
}

/// Outcome of checking one installed app.
public enum AppReleaseStatus: Sendable, Equatable {
    case available(AppReleaseCandidate, AppReleaseInstallStrategy)
    case upToDate(latest: AppReleaseCandidate?)
    /// The user ignores this app entirely.
    case ignored
    /// The user skipped exactly this version.
    case skippedVersion(String)
    /// No source knows this app.
    case untracked
    /// Every matching source failed (network, parse).
    case failed(String)
}

/// One row of the App Updater list.
public struct AppReleaseRow: Sendable, Equatable, Identifiable {
    public var id: String { app.bundleID }
    public let app: InstalledApp
    public let status: AppReleaseStatus
    /// What the Source column names: the source of the release the row
    /// offers or reports, or, with no release to name, the sources consulted.
    public let sources: [AppReleaseSourceKind]

    public init(app: InstalledApp, status: AppReleaseStatus, sources: [AppReleaseSourceKind] = []) {
        self.app = app
        self.status = status
        self.sources = sources
    }

    public var availableCandidate: AppReleaseCandidate? {
        if case .available(let candidate, _) = status { return candidate }
        return nil
    }

    /// The offered update, unless the app's own updater installs it. Those
    /// need nothing from the user, so counts, the badge and notices skip them.
    public var actionableCandidate: AppReleaseCandidate? {
        if case .available(_, .updatesItself) = status { return nil }
        return availableCandidate
    }
}

/// What one source reported for one app.
public enum AppReleaseSourceOutcome: Sendable, Equatable {
    /// The newest stable release this Mac can run.
    case found(AppReleaseCandidate)
    /// The source knows the app but offers nothing eligible (only betas,
    /// only releases for a newer macOS, or an empty feed).
    case noEligibleRelease
    /// The source knows the app but the lookup failed.
    case failed(String)
}

/// A provider of release candidates. One batch call per check run; apps the
/// source doesn't know are absent from the result.
public protocol AppReleaseSourcing: Sendable {
    var kind: AppReleaseSourceKind { get }
    func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome]
}
