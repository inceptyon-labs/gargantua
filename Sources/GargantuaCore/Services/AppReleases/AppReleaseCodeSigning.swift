import Foundation
import Security

/// Outcome of a strict code-signature check on a staged update.
public struct AppReleaseSignatureReport: Sendable, Equatable {
    /// The signature, every nested code item, and every sealed resource
    /// validated.
    public let isValid: Bool
    public let teamID: String?
    /// Signed with a Developer ID Application certificate issued by Apple.
    public let isDeveloperID: Bool
    /// Why validation failed, when it did.
    public let failure: String?

    public init(isValid: Bool, teamID: String?, isDeveloperID: Bool, failure: String? = nil) {
        self.isValid = isValid
        self.teamID = teamID
        self.isDeveloperID = isDeveloperID
        self.failure = failure
    }
}

/// Code-signature seam for the App Updater's install verification.
public protocol AppReleaseCodeSigning: Sendable {
    func assess(bundleURL: URL) -> AppReleaseSignatureReport
}

/// Full signature validation, equivalent to `codesign --verify --deep --strict`.
///
/// Unlike `DefaultCodeSignatureVerifier`, this hashes every sealed resource:
/// the bundle is about to replace one the user already trusts, so a tampered
/// resource has to fail here.
public struct StrictAppReleaseCodeSigner: AppReleaseCodeSigning {
    static let validationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    )

    /// Apple-anchored chain whose intermediate is the Developer ID CA and whose
    /// leaf is a Developer ID Application certificate.
    static let developerIDRequirement = "anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    public init() {}

    public func assess(bundleURL: URL) -> AppReleaseSignatureReport {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return AppReleaseSignatureReport(
                isValid: false,
                teamID: nil,
                isDeveloperID: false,
                failure: Self.describe(status: createStatus, error: nil)
            )
        }

        let teamID = Self.teamIdentifier(of: code)

        var validityError: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, Self.validationFlags, nil, &validityError)
        guard validity == errSecSuccess else {
            return AppReleaseSignatureReport(
                isValid: false,
                teamID: teamID,
                isDeveloperID: false,
                failure: Self.describe(status: validity, error: validityError?.takeRetainedValue())
            )
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.developerIDRequirement as CFString, SecCSFlags(), &requirement)
            == errSecSuccess, let requirement
        else {
            return AppReleaseSignatureReport(
                isValid: true,
                teamID: teamID,
                isDeveloperID: false,
                failure: "Could not build the Developer ID requirement."
            )
        }
        var requirementError: Unmanaged<CFError>?
        let requirementStatus = SecStaticCodeCheckValidityWithErrors(
            code,
            Self.validationFlags,
            requirement,
            &requirementError
        )
        let isDeveloperID = requirementStatus == errSecSuccess
        return AppReleaseSignatureReport(
            isValid: true,
            teamID: teamID,
            isDeveloperID: isDeveloperID,
            failure: isDeveloperID
                ? nil
                : Self.describe(status: requirementStatus, error: requirementError?.takeRetainedValue())
        )
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Security's message for the status (e.g. "a sealed resource is missing
    /// or invalid") reads better than the CFError's generic description.
    private static func describe(status: OSStatus, error: CFError?) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return error.map { ($0 as Error).localizedDescription } ?? "Code signature check failed (OSStatus \(status))."
    }
}

/// What Gatekeeper said about a staged bundle.
public struct AppReleaseGatekeeperVerdict: Sendable, Equatable {
    public let accepted: Bool
    /// The `source=` line, e.g. `Notarized Developer ID`.
    public let source: String?
    public let detail: String

    public init(accepted: Bool, source: String?, detail: String) {
        self.accepted = accepted
        self.source = source
        self.detail = detail
    }
}

/// Gatekeeper/notarization seam for the App Updater's install verification.
public protocol AppReleaseGatekeeperAssessing: Sendable {
    func assess(bundleURL: URL) -> AppReleaseGatekeeperVerdict
}

/// Asks Gatekeeper through `spctl --assess --type execute`. Accepts only a
/// zero exit with `source=Notarized Developer ID`; anything else, including a
/// failure to run `spctl`, is a rejection.
public struct SpctlAppReleaseGatekeeper: AppReleaseGatekeeperAssessing {
    static let executable = URL(fileURLWithPath: "/usr/sbin/spctl")
    static let requiredSource = "Notarized Developer ID"

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner = DefaultProcessRunner()) {
        self.runner = runner
    }

    public func assess(bundleURL: URL) -> AppReleaseGatekeeperVerdict {
        let output: ProcessOutput
        do {
            output = try runner.run(
                executable: Self.executable,
                arguments: ["--assess", "--type", "execute", "--verbose=2", bundleURL.path],
                timeout: 60,
                maxCapturedBytes: 64 * 1024
            )
        } catch {
            return AppReleaseGatekeeperVerdict(accepted: false, source: nil, detail: error.localizedDescription)
        }
        let source = Self.parseSource(output.stderr)
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppReleaseGatekeeperVerdict(
            accepted: output.exitCode == 0 && source == Self.requiredSource,
            source: source,
            detail: detail.isEmpty ? "spctl exited with status \(output.exitCode)." : detail
        )
    }

    static func parseSource(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("source=") {
                return String(trimmed.dropFirst("source=".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
