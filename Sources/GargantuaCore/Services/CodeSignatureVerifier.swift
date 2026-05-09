import Foundation
import Security

/// Result of verifying a bundle's code signature.
public struct CodeSignatureInfo: Sendable, Equatable {
    /// `true` if the signature validated, `false` if it is invalid or missing,
    /// `nil` if the signature could not be evaluated (e.g., path unreadable).
    public let valid: Bool?

    /// Team identifier (e.g., `EQHXZ8M8AV`) from the signing certificate chain, when readable.
    public let teamIdentifier: String?

    public init(valid: Bool?, teamIdentifier: String?) {
        self.valid = valid
        self.teamIdentifier = teamIdentifier
    }

    /// Sentinel for bundles that could not be evaluated at all.
    public static let unknown = CodeSignatureInfo(valid: nil, teamIdentifier: nil)
}

/// Extended signature facts used by `BinaryIdentityResolver`.
///
/// Adds the leaf certificate's Common Name (`signingIdentity`), a notarization
/// flag derived from a local `Security.framework` requirement check, and
/// whether the signature was anchored at Apple (first-party) or via Apple's
/// generic Developer ID anchor.
public struct CodeSignatureDetails: Sendable, Equatable {
    public let valid: Bool?
    public let teamIdentifier: String?
    public let signingIdentity: String?
    public let isNotarized: Bool?
    /// `true` if the binary satisfies `anchor apple` (Apple-shipped platform binaries).
    public let isAppleAnchor: Bool
    /// `true` if the binary satisfies `anchor apple generic` (any Developer ID-signed binary).
    public let isAppleGenericAnchor: Bool

    public init(
        valid: Bool?,
        teamIdentifier: String?,
        signingIdentity: String?,
        isNotarized: Bool?,
        isAppleAnchor: Bool,
        isAppleGenericAnchor: Bool
    ) {
        self.valid = valid
        self.teamIdentifier = teamIdentifier
        self.signingIdentity = signingIdentity
        self.isNotarized = isNotarized
        self.isAppleAnchor = isAppleAnchor
        self.isAppleGenericAnchor = isAppleGenericAnchor
    }

    public static let unknown = CodeSignatureDetails(
        valid: nil,
        teamIdentifier: nil,
        signingIdentity: nil,
        isNotarized: nil,
        isAppleAnchor: false,
        isAppleGenericAnchor: false
    )
}

/// Abstraction over `SecStaticCode` so the scanner can be unit-tested with stubs.
public protocol CodeSignatureVerifying: Sendable {
    func verify(bundleURL: URL) -> CodeSignatureInfo
}

/// Optional richer view used by the Background Activity Review pipeline.
///
/// Implementers that conform get notarization + signing-identity inspection
/// for free. Existing call sites that only need `verify(bundleURL:)` are
/// unaffected.
public protocol DetailedCodeSignatureVerifying: CodeSignatureVerifying {
    func verifyDetails(bundleURL: URL) -> CodeSignatureDetails
}

/// Production implementation backed by `Security.framework`'s `SecStaticCode` APIs.
///
/// Uses only offline, local validation flags — no network calls to Apple for
/// notarisation checks. The notarisation requirement check uses the local
/// stapled ticket / cdhash cache.
public struct DefaultCodeSignatureVerifier: DetailedCodeSignatureVerifying {
    public init() {}

    public func verify(bundleURL: URL) -> CodeSignatureInfo {
        guard let code = staticCode(for: bundleURL) else { return .unknown }

        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess
        let teamID = signingDictionary(for: code)?[kSecCodeInfoTeamIdentifier as String] as? String
        return CodeSignatureInfo(valid: valid, teamIdentifier: teamID)
    }

    public func verifyDetails(bundleURL: URL) -> CodeSignatureDetails {
        guard let code = staticCode(for: bundleURL) else { return .unknown }

        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess
        let info = signingDictionary(for: code)
        let teamID = info?[kSecCodeInfoTeamIdentifier as String] as? String

        let signingIdentity: String?
        if let certs = info?[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first {
            var commonName: CFString?
            if SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
               let cn = commonName as String? {
                signingIdentity = cn
            } else {
                signingIdentity = nil
            }
        } else {
            signingIdentity = nil
        }

        let isAppleAnchor = checkRequirement("anchor apple", code: code) == true
        let isAppleGenericAnchor = isAppleAnchor
            || checkRequirement("anchor apple generic", code: code) == true

        // Notarisation: locally check via the `notarized` requirement keyword.
        // This consults the stapled ticket or local cdhash cache populated by
        // Gatekeeper — no network round-trip.
        let isNotarized: Bool?
        if valid {
            isNotarized = checkRequirement("notarized", code: code)
        } else {
            isNotarized = nil
        }

        return CodeSignatureDetails(
            valid: valid,
            teamIdentifier: teamID,
            signingIdentity: signingIdentity,
            isNotarized: isNotarized,
            isAppleAnchor: isAppleAnchor,
            isAppleGenericAnchor: isAppleGenericAnchor
        )
    }

    private func staticCode(for bundleURL: URL) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess else { return nil }
        return staticCode
    }

    private func signingDictionary(for code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess, let dict = info as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func checkRequirement(_ requirement: String, code: SecStaticCode) -> Bool? {
        var req: SecRequirement?
        let createStatus = SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(rawValue: 0),
            &req
        )
        guard createStatus == errSecSuccess, let requirement = req else { return nil }
        let status = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: 0),
            requirement
        )
        return status == errSecSuccess
    }
}
