import Foundation

/// Coarse classification of who signed a binary.
///
/// Used by the Background Activity Review surface to decide default safety
/// posture: Apple → protected, third-party-known → safe-by-default,
/// third-party-unknown → review, unsigned → review.
public enum VendorClassification: String, Sendable, Equatable, Codable {
    /// Signed by Apple's first-party platform anchor (system binaries, Apple-shipped tools).
    case apple
    /// Signed with a Developer ID anchor and the Team ID is in the curated registry.
    case thirdPartyKnown = "third_party_known"
    /// Signed with a Developer ID anchor but the Team ID is not curated.
    case thirdPartyUnknown = "third_party_unknown"
    /// Either has no valid signature, or `SecStaticCode` could not evaluate it.
    case unsigned
}

/// Categories of vendor that default to `review` regardless of signature validity
/// because the things they do (intercept input, route traffic, manage devices,
/// access keychain, etc.) deserve a second look before disabling/removing.
public enum SensitiveVendorCategory: String, Sendable, Equatable, Hashable, Codable {
    /// VPN clients, network extensions that route traffic.
    case vpn
    /// Password managers and credential vaults.
    case passwordManager = "password_manager"
    /// Mobile Device Management agents.
    case mdm
    /// Accessibility / input helpers (key-remappers, automation tools).
    case accessibility
    /// Backup or sync clients.
    case backup
    /// Security / anti-virus / endpoint protection.
    case security
}

/// Resolved identity for a binary path on disk.
///
/// Combines bundle metadata, code-signature facts, and a coarse vendor
/// classification. The `sensitiveCategories` set is non-empty for vendors that
/// must default to `review` even when properly signed.
public struct BinaryIdentity: Sendable, Equatable {
    /// The original binary path the resolver was given.
    public let binaryPath: String

    /// The resolved bundle (`.app`, `.framework`, `.appex`) the binary lives in,
    /// or `nil` if the binary is not inside a bundle (e.g. `/usr/local/bin/foo`).
    public let bundlePath: String?

    /// `CFBundleIdentifier` from the bundle's Info.plist, or `nil` if unbundled
    /// or unreadable.
    public let bundleIdentifier: String?

    /// `CFBundleName` from the bundle's Info.plist.
    public let bundleName: String?

    /// `CFBundleShortVersionString` from the bundle's Info.plist.
    public let bundleShortVersion: String?

    /// Team Identifier from the leaf signing certificate (e.g. `EQHXZ8M8AV`).
    public let teamIdentifier: String?

    /// Common Name of the leaf signing certificate
    /// (e.g. `Developer ID Application: Acme Corp (ABCDE12345)`).
    public let signingIdentity: String?

    /// `true` if the static signature validated, `false` if invalid, `nil` if
    /// `SecStaticCode` could not be evaluated at all.
    public let signatureValid: Bool?

    /// `true` if a notarization ticket is locally available for this binary,
    /// `false` if absent, `nil` if the check could not be performed.
    public let isNotarized: Bool?

    /// Coarse classification of who signed it.
    public let vendor: VendorClassification

    /// Display name from the registry if matched (e.g. `1Password`,
    /// `Microsoft Defender`). Falls back to bundle name at the call site.
    public let vendorDisplayName: String?

    /// Categories the vendor falls into. Empty means "not sensitive."
    public let sensitiveCategories: Set<SensitiveVendorCategory>

    public init(
        binaryPath: String,
        bundlePath: String? = nil,
        bundleIdentifier: String? = nil,
        bundleName: String? = nil,
        bundleShortVersion: String? = nil,
        teamIdentifier: String? = nil,
        signingIdentity: String? = nil,
        signatureValid: Bool? = nil,
        isNotarized: Bool? = nil,
        vendor: VendorClassification,
        vendorDisplayName: String? = nil,
        sensitiveCategories: Set<SensitiveVendorCategory> = []
    ) {
        self.binaryPath = binaryPath
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.bundleShortVersion = bundleShortVersion
        self.teamIdentifier = teamIdentifier
        self.signingIdentity = signingIdentity
        self.signatureValid = signatureValid
        self.isNotarized = isNotarized
        self.vendor = vendor
        self.vendorDisplayName = vendorDisplayName
        self.sensitiveCategories = sensitiveCategories
    }

    /// `true` if the vendor falls into any sensitive category — Background
    /// Activity Review uses this to override "third-party-known → safe" defaults.
    public var isSensitiveVendor: Bool {
        !sensitiveCategories.isEmpty
    }
}
