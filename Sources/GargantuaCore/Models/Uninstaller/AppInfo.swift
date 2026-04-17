import Foundation

/// Metadata describing a single installed macOS application.
///
/// Populated from NSWorkspace / Launch Services during uninstall discovery.
/// The concrete scanner that builds an `AppInfo` lives outside this target;
/// this type only models the data the Trust Layer and remnant rules
/// consume.
public struct AppInfo: Codable, Sendable, Identifiable, Equatable {
    /// Primary key — the bundle identifier (e.g., `com.google.Chrome`).
    public var id: String { bundleID }

    /// macOS bundle identifier (e.g., `com.google.Chrome`).
    public let bundleID: String

    /// Canonical app name as written in `CFBundleName` (e.g., `Google Chrome`).
    public let name: String

    /// User-facing display name (e.g., `CFBundleDisplayName`), when different.
    public let displayName: String?

    /// Short marketing version string (e.g., `17.4.1`).
    public let shortVersion: String?

    /// Build/bundle version string (e.g., `CFBundleVersion`).
    public let bundleVersion: String?

    /// Absolute path to the app bundle (e.g., `/Applications/Chrome.app`).
    public let bundlePath: String

    /// Absolute path to the primary executable, when known.
    public let executablePath: String?

    /// File-system creation date for the bundle, when known.
    public let installDate: Date?

    /// Most-recent known usage timestamp (launch or access), when known.
    public let lastUsedDate: Date?

    /// Whether the app is currently running (NSRunningApplication check).
    public let isRunning: Bool

    /// Whether the app lives inside `/System/` or is Apple-signed system software.
    public let isSystemApp: Bool

    /// Apparent on-disk size of the bundle in bytes, when measured.
    public let sizeOnDisk: Int64?

    /// Team identifier from the code signature, when readable.
    public let teamIdentifier: String?

    /// Whether the bundle's code signature validated successfully.
    ///
    /// `nil` if the signature has not been checked yet. This surfaces to the
    /// Trust Layer: unsigned or broken-signature apps raise confirmation tier.
    public let signatureValid: Bool?

    public init(
        bundleID: String,
        name: String,
        displayName: String? = nil,
        shortVersion: String? = nil,
        bundleVersion: String? = nil,
        bundlePath: String,
        executablePath: String? = nil,
        installDate: Date? = nil,
        lastUsedDate: Date? = nil,
        isRunning: Bool = false,
        isSystemApp: Bool = false,
        sizeOnDisk: Int64? = nil,
        teamIdentifier: String? = nil,
        signatureValid: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.installDate = installDate
        self.lastUsedDate = lastUsedDate
        self.isRunning = isRunning
        self.isSystemApp = isSystemApp
        self.sizeOnDisk = sizeOnDisk
        self.teamIdentifier = teamIdentifier
        self.signatureValid = signatureValid
    }
}
