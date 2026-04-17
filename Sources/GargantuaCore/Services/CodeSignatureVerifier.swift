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

/// Abstraction over `SecStaticCode` so the scanner can be unit-tested with stubs.
public protocol CodeSignatureVerifying: Sendable {
    func verify(bundleURL: URL) -> CodeSignatureInfo
}

/// Production implementation backed by `Security.framework`'s `SecStaticCode` APIs.
///
/// Uses only offline, local validation flags — no network calls to Apple for
/// notarisation checks.
public struct DefaultCodeSignatureVerifier: CodeSignatureVerifying {
    public init() {}

    public func verify(bundleURL: URL) -> CodeSignatureInfo {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .unknown
        }

        let validateStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: 0),
            nil
        )
        let valid = validateStatus == errSecSuccess

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        var teamID: String?
        if infoStatus == errSecSuccess, let dict = info as? [String: Any] {
            teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        }
        return CodeSignatureInfo(valid: valid, teamIdentifier: teamID)
    }
}
