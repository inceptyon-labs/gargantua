import CryptoKit
import Darwin
import Foundation

/// Why a downloaded update was refused. Cases are grouped by the verification
/// step that raises them, in pipeline order.
public enum AppReleaseVerificationFailure: Error, Equatable, LocalizedError {
    // Source policy
    case missingDownloadURL
    case insecureDownloadURL(String)
    case installerPackage
    case notInPlaceStrategy
    // Length
    case unreadablePayload(String)
    case downloadTooLarge(limit: Int64)
    case lengthMismatch(expected: Int64, actual: Int64)
    // SHA-256
    case checksumMismatch
    // EdDSA
    case feedSignatureMissing
    case publicKeyMissing
    case malformedPublicKey
    case malformedSignature
    case signatureInvalid
    // Payload sniff
    case unrecognizedPayload
    case payloadKindMismatch(declared: AppReleasePayloadKind, actual: AppReleasePayloadKind)
    // Archive entries and extraction
    case unsafeArchiveEntry(String)
    case insufficientDiskSpace(needed: Int64, available: Int64?)
    case extractionFailed(String)
    case extractedTooLarge(limit: Int64)
    case licenseAgreementRequired
    case encryptedDiskImage
    // Locating the app
    case appNotFound
    case multipleMatchingApps
    // Tree walk
    case symlinkEscapesBundle(String)
    case specialFile(String)
    case missingInfoPlist
    // Code signature
    case invalidCodeSignature(String)
    case notDeveloperID
    // Team ID
    case installedTeamIDMissing
    case teamIDMismatch(expected: String, actual: String?)
    case pinnedTeamIDMismatch(expected: String, actual: String?)
    case teamCertificateMismatch(String)
    // Gatekeeper
    case gatekeeperRejected(String)
    // Version
    case notNewer(staged: String, installed: String)
    case requiresNewerMacOS(String)

    public var errorDescription: String? {
        switch self {
        case .missingDownloadURL: "The update has no download address."
        case .insecureDownloadURL(let url): "The update would download over an insecure connection: \(url)"
        case .installerPackage: "The update is an installer package, which Gargantua doesn't install."
        case .notInPlaceStrategy: "This update can't be installed in place."
        case .unreadablePayload(let detail): "The downloaded file couldn't be read: \(detail)"
        case .downloadTooLarge(let limit): "The download is larger than the \(limit / 1_073_741_824) GB limit."
        case .lengthMismatch(let expected, let actual):
            "The download is \(actual) bytes, but the vendor said it would be \(expected) bytes."
        case .checksumMismatch: "The download doesn't match the checksum its source published."
        case .feedSignatureMissing:
            "The app's update feed is missing its signature, so the download can't be proven to come from the developer."
        case .publicKeyMissing:
            "The update is signed, but the installed app has no key to check the signature against."
        case .malformedPublicKey: "The installed app's update-signing key is not a valid key."
        case .malformedSignature: "The update's signature is not in a valid format."
        case .signatureInvalid: "The update's signature doesn't match the developer's signing key."
        case .unrecognizedPayload: "The download isn't a zip, disk image, or tar archive."
        case .payloadKindMismatch(let declared, let actual):
            "The download was described as \(declared.rawValue) but is actually \(actual.rawValue)."
        case .unsafeArchiveEntry(let path): "The archive contains an unsafe path: \(path)"
        case .insufficientDiskSpace(let needed, let available):
            if let available {
                "Not enough free disk space to unpack the update: it needs \(Self.bytes(needed)) free, "
                    + "and \(Self.bytes(available)) is available."
            } else {
                "Not enough free disk space to unpack the update: the free space couldn't be read."
            }
        case .extractionFailed(let detail): "The download couldn't be unpacked: \(detail)"
        case .extractedTooLarge(let limit): "The unpacked update is larger than the \(Self.bytes(limit)) limit."
        case .licenseAgreementRequired:
            "The disk image asks you to accept a license agreement. Download and install this update by hand."
        case .encryptedDiskImage:
            "The disk image is password-protected, so Gargantua can't open it. Get the update from the vendor instead."
        case .appNotFound: "The download doesn't contain this app."
        case .multipleMatchingApps: "The download contains more than one copy of this app."
        case .symlinkEscapesBundle(let path): "The new app contains a link that points outside itself: \(path)"
        case .specialFile(let path): "The new app contains a device, pipe, or socket file: \(path)"
        case .missingInfoPlist: "The new app is missing its Info.plist."
        case .invalidCodeSignature(let detail): "The new app's code signature is not valid: \(detail)"
        case .notDeveloperID: "The new app isn't signed with an Apple Developer ID."
        case .installedTeamIDMissing:
            "The installed app has no developer team ID, so the update can't be matched to the same developer."
        case .teamIDMismatch(let expected, let actual):
            "The update is signed by a different developer (\(actual ?? "none")) than the installed app (\(expected))."
        case .pinnedTeamIDMismatch(let expected, let actual):
            "The update is signed by \(actual ?? "no developer"), not the expected developer \(expected)."
        case .teamCertificateMismatch(let team):
            "The update's signing certificate wasn't issued by Apple to the developer team \(team)."
        case .gatekeeperRejected(let detail): "macOS Gatekeeper rejected the new app: \(detail)"
        case .notNewer(let staged, let installed):
            "The download is version \(staged), which is not newer than the installed \(installed)."
        case .requiresNewerMacOS(let minimum): "The new version needs macOS \(minimum) or later."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A verified app bundle sitting in the staging directory, ready to swap in.
public struct AppReleaseStagedBundle: Sendable, Equatable {
    public let url: URL
    public let version: AppReleaseVersion

    public init(url: URL, version: AppReleaseVersion) {
        self.url = url
        self.version = version
    }
}

/// Verification seam for `AppReleaseInstaller`.
public protocol AppReleaseVerifying: Sendable {
    /// The source-policy check alone, so nothing is downloaded for a
    /// candidate that can't pass.
    func checkSourcePolicy(
        _ candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy
    ) throws(AppReleaseVerificationFailure)

    /// Every check on a downloaded payload. Unpacks into `workDirectory` and
    /// returns the staged bundle that passed them all. `app` carries the
    /// version on disk now, which the staged bundle must be newer than.
    func verify(
        payload: URL,
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy,
        workDirectory: URL
    ) throws(AppReleaseVerificationFailure) -> AppReleaseStagedBundle
}

/// Verifies a downloaded update before it may replace an installed app. Every
/// step fails closed.
///
/// The staged bundle is not re-verified right before the swap: the staging
/// directory is created 0700 under the user's own Caches, so only same-uid
/// code could tamper with it, and same-uid code can already rewrite the
/// installed app.
public struct AppReleaseVerifier: AppReleaseVerifying {
    public static let maxPayloadBytes: Int64 = 4 * 1_073_741_824
    static let maxListingBytes = 64 * 1_048_576

    private let signer: any AppReleaseCodeSigning
    private let gatekeeper: any AppReleaseGatekeeperAssessing
    let runner: any ProcessRunner
    private let hostOSVersion: OperatingSystemVersion

    public init(
        signer: any AppReleaseCodeSigning = StrictAppReleaseCodeSigner(),
        gatekeeper: any AppReleaseGatekeeperAssessing = SpctlAppReleaseGatekeeper(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        hostOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.signer = signer
        self.gatekeeper = gatekeeper
        self.runner = runner
        self.hostOSVersion = hostOSVersion
    }

    public func verify(
        payload: URL,
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy,
        workDirectory: URL
    ) throws(AppReleaseVerificationFailure) -> AppReleaseStagedBundle {
        try checkSourcePolicy(candidate, strategy: strategy)
        let payloadSize = try Self.checkLength(of: payload, expected: candidate.expectedLength)
        try Self.checkSHA256(of: payload, expected: candidate.sha256)
        try Self.checkEdSignature(of: payload, app: app, candidate: candidate)
        let kind = try Self.sniffPayload(payload, declared: candidate.payloadKind)

        let extracted = workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try Self.makeEmptyDirectory(extracted)
        let available = Self.availableCapacity(at: workDirectory)
        try Self.checkFreeSpace(available: available, payloadSize: payloadSize)
        try unpack(
            payload,
            kind: kind,
            into: extracted,
            mountRoot: workDirectory.appendingPathComponent("mounts", isDirectory: true),
            bundleID: app.bundleID,
            budget: Self.extractionBudget(available: available)
        )
        try Self.checkExtractedSize(Self.treeSize(of: extracted, limit: Self.maxExtractedBytes))

        let bundle = try Self.locateApp(in: extracted, bundleID: app.bundleID)
        try Self.walkBundleTree(bundle)
        let report = try checkCodeSignature(bundle, requiredTeams: Self.requiredTeams(app: app, candidate: candidate))
        try Self.checkTeamID(report.teamID, app: app, candidate: candidate)
        try Self.checkTeamCertificate(report)
        try checkGatekeeper(bundle)
        let version = try Self.checkVersion(of: bundle, installed: app, hostOSVersion: hostOSVersion)
        return AppReleaseStagedBundle(url: bundle, version: version)
    }

    // MARK: - Source policy

    public func checkSourcePolicy(
        _ candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy
    ) throws(AppReleaseVerificationFailure) {
        guard let url = candidate.downloadURL else { throw .missingDownloadURL }
        guard url.isHTTPS else { throw .insecureDownloadURL(url.absoluteString) }
        guard candidate.payloadKind.isInstallable else { throw .installerPackage }
        guard strategy == .inPlace, candidate.allowsInPlaceInstall else { throw .notInPlaceStrategy }
    }

    // MARK: - Length

    /// A declared length of zero or less is treated as undeclared: appcasts
    /// often publish `length="0"`, and no real payload is empty.
    @discardableResult
    static func checkLength(of payload: URL, expected: Int64?) throws(AppReleaseVerificationFailure) -> Int64 {
        var info = stat()
        guard lstat(payload.path, &info) == 0 else { throw .unreadablePayload(Self.errnoMessage()) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .unreadablePayload("not a regular file") }
        let size = Int64(info.st_size)
        guard size <= maxPayloadBytes else { throw .downloadTooLarge(limit: maxPayloadBytes) }
        if let expected, expected > 0, expected != size {
            throw .lengthMismatch(expected: expected, actual: size)
        }
        return size
    }

    // MARK: - SHA-256

    static func checkSHA256(of payload: URL, expected: String?) throws(AppReleaseVerificationFailure) {
        guard let expected else { return }
        let actual = try sha256Hex(of: payload)
        guard actual == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw .checksumMismatch
        }
    }

    /// Streams the file in 1 MiB reads so a large payload is never held in memory.
    static func sha256Hex(of url: URL) throws(AppReleaseVerificationFailure) -> String {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw .unreadablePayload(Self.errnoMessage()) }
        defer { close(descriptor) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadablePayload(Self.errnoMessage())
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - EdDSA

    /// Required when the item carries a signature, or when it comes from a
    /// Sparkle feed and the installed app publishes a key; skipped only when
    /// neither side has anything.
    static func checkEdSignature(
        of payload: URL,
        app: InstalledApp,
        candidate: AppReleaseCandidate
    ) throws(AppReleaseVerificationFailure) {
        let key = app.sparklePublicEDKey?.trimmedNonEmpty
        let signature = candidate.edSignature?.trimmedNonEmpty
        guard signature != nil || (candidate.isSparkleFeed && key != nil) else { return }
        guard let key else { throw .publicKeyMissing }
        guard let signature else { throw .feedSignatureMissing }

        guard let keyData = Data(base64Encoded: key), keyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw .malformedPublicKey }
        guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else {
            throw .malformedSignature
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: payload, options: .alwaysMapped)
        } catch {
            throw .unreadablePayload(error.localizedDescription)
        }
        guard publicKey.isValidSignature(signatureData, for: bytes) else { throw .signatureInvalid }
    }

    // MARK: - Payload sniff

    static func sniffPayload(
        _ payload: URL,
        declared: AppReleasePayloadKind
    ) throws(AppReleaseVerificationFailure) -> AppReleasePayloadKind {
        let (head, tail) = try readHeadAndTail(of: payload)
        let sniffed = try sniff(head: head, tail: tail)
        if declared != .unknown, declared != sniffed {
            throw .payloadKindMismatch(declared: declared, actual: sniffed)
        }
        return sniffed
    }

    /// The UDIF trailer is checked first: a bzip2-compressed disk image also
    /// starts with `BZh`. An encrypted image has no readable trailer and is
    /// refused from its `encrcdsa` header: its key-derivation cost is set by
    /// whoever built it, so attaching one can keep `diskimages-helper` busy
    /// past any timeout. A v1 encrypted image carries a `cdsaencr` header at
    /// the end of the file, so a `koly` trailer is only trusted when the last
    /// 4096 bytes hold no such header.
    static func sniff(head: [UInt8], tail: [UInt8]?) throws(AppReleaseVerificationFailure) -> AppReleasePayloadKind {
        if head.starts(with: Array("xar!".utf8)) { throw .installerPackage }
        if head.starts(with: Array("encrcdsa".utf8)) { throw .encryptedDiskImage }
        if let tail, tail.count >= 512, tail.suffix(512).starts(with: Array("koly".utf8)) {
            if containsSubsequence(tail, Array("cdsaencr".utf8)) { throw .encryptedDiskImage }
            return .dmg
        }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if head.starts(with: [0x1F, 0x8B])
            || head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
            || head.starts(with: Array("BZh".utf8)) {
            return .tar
        }
        if head.count >= 262, Array(head[257 ..< 262]) == Array("ustar".utf8) { return .tar }
        throw .unrecognizedPayload
    }

    private static func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return (0 ... haystack.count - needle.count).contains { haystack[$0 ..< $0 + needle.count].elementsEqual(needle) }
    }

    private static func readHeadAndTail(of url: URL) throws(AppReleaseVerificationFailure) -> ([UInt8], [UInt8]?) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw .unreadablePayload(Self.errnoMessage()) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadablePayload(Self.errnoMessage()) }

        func readBlock(at offset: off_t, length: Int = 512) -> [UInt8] {
            var block = [UInt8](repeating: 0, count: length)
            let count = block.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, offset) }
            return count > 0 ? Array(block.prefix(count)) : []
        }
        let head = readBlock(at: 0)
        let tailLength = Int(min(info.st_size, 4096))
        let tail = info.st_size >= 512 ? readBlock(at: info.st_size - off_t(tailLength), length: tailLength) : nil
        return (head, tail)
    }

    // MARK: - Code signature

    private func checkCodeSignature(
        _ bundle: URL,
        requiredTeams: [String]
    ) throws(AppReleaseVerificationFailure) -> AppReleaseSignatureReport {
        let report = signer.assess(bundleURL: bundle, requiredTeams: requiredTeams)
        guard report.isValid else { throw .invalidCodeSignature(report.failure ?? "unknown error") }
        guard report.isDeveloperID else { throw .notDeveloperID }
        return report
    }

    // MARK: - Team ID

    static func checkTeamID(
        _ stagedTeamID: String?,
        app: InstalledApp,
        candidate: AppReleaseCandidate
    ) throws(AppReleaseVerificationFailure) {
        guard let installed = app.teamID?.trimmedNonEmpty else { throw .installedTeamIDMissing }
        guard stagedTeamID == installed else { throw .teamIDMismatch(expected: installed, actual: stagedTeamID) }
        if let pinned = candidate.pinnedTeamID, pinned != stagedTeamID {
            throw .pinnedTeamIDMismatch(expected: pinned, actual: stagedTeamID)
        }
    }

    /// The Team ID field alone is just a string in the signature; Apple must
    /// also have issued the leaf certificate to that team, for the installed
    /// app's team and any catalog-pinned one. The signer checks these in the
    /// same pass as the signature.
    static func requiredTeams(app: InstalledApp, candidate: AppReleaseCandidate) -> [String] {
        var teams = [app.teamID?.trimmedNonEmpty].compactMap { $0 }
        if let pinned = candidate.pinnedTeamID, !teams.contains(pinned) { teams.append(pinned) }
        return teams
    }

    static func checkTeamCertificate(_ report: AppReleaseSignatureReport) throws(AppReleaseVerificationFailure) {
        if let team = report.uncertifiedTeam { throw .teamCertificateMismatch(team) }
    }

    // MARK: - Gatekeeper

    private func checkGatekeeper(_ bundle: URL) throws(AppReleaseVerificationFailure) {
        let verdict = gatekeeper.assess(bundleURL: bundle)
        guard verdict.accepted else { throw .gatekeeperRejected(verdict.detail) }
    }

    // MARK: - Version

    static func checkVersion(
        of bundle: URL,
        installed: InstalledApp,
        hostOSVersion: OperatingSystemVersion
    ) throws(AppReleaseVerificationFailure) -> AppReleaseVersion {
        guard let plist = AppBundleFiles.infoPlist(ofBundle: bundle) else { throw .missingInfoPlist }
        let staged = AppReleaseVersion(plist: plist)
        guard staged.isNewer(than: installed.version) else {
            throw .notNewer(staged: staged.description, installed: installed.version.description)
        }
        if let minimum = plist["LSMinimumSystemVersion"] {
            let text = (minimum as? String) ?? String(describing: minimum)
            // Unparsable fails closed, like an unmet minimum.
            guard hostOSVersion.meets(minimum: text) == true else { throw .requiresNewerMacOS(text) }
        }
        return staged
    }

    // MARK: - Helpers

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
