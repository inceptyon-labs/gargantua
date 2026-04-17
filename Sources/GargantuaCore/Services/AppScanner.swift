import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "AppScanner")

/// Abstraction over running-process detection so the scanner can be unit-tested.
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleID: String) -> Bool
}

/// Production implementation backed by `NSRunningApplication`.
public struct DefaultRunningAppChecker: RunningAppChecking {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Scans installed macOS applications and produces `AppInfo` records for the
/// Smart Uninstaller pipeline.
public protocol AppScanning: Sendable {
    func scanApps() async -> [AppInfo]
}

/// Default scanner: composes an enumerator, a bundle reader, a running-app
/// checker, and a code-signature verifier into a list of `AppInfo` records,
/// deduplicated by bundle identifier.
///
/// The scanner only *reads* — it never writes to `SafetyLevel` or any other
/// Trust Layer state. Consumers remain responsible for classifying remnants
/// downstream.
public struct DefaultAppScanner: AppScanning {
    private let enumerator: AppBundleEnumerating
    private let reader: AppBundleReading
    private let runningChecker: RunningAppChecking
    private let signatureVerifier: CodeSignatureVerifying
    private let systemAppPrefixes: [String]

    public init(
        enumerator: AppBundleEnumerating = DefaultAppBundleEnumerator(),
        reader: AppBundleReading = DefaultAppBundleReader(),
        runningChecker: RunningAppChecking = DefaultRunningAppChecker(),
        signatureVerifier: CodeSignatureVerifying = DefaultCodeSignatureVerifier(),
        systemAppPrefixes: [String] = ["/System/"]
    ) {
        self.enumerator = enumerator
        self.reader = reader
        self.runningChecker = runningChecker
        self.signatureVerifier = signatureVerifier
        self.systemAppPrefixes = systemAppPrefixes
    }

    public func scanApps() async -> [AppInfo] {
        let bundles = enumerator.enumerateBundles()
        logger.info("AppScanner: enumerated \(bundles.count, privacy: .public) bundle candidate(s)")

        var byBundleID: [String: AppInfo] = [:]
        var order: [String] = []

        for bundleURL in bundles {
            guard let metadata = reader.readMetadata(bundleURL: bundleURL) else {
                logger.debug("AppScanner: skipping unreadable bundle at \(bundleURL.path, privacy: .public)")
                continue
            }

            let signature = signatureVerifier.verify(bundleURL: bundleURL)
            let isRunning = runningChecker.isRunning(bundleID: metadata.bundleID)
            let isSystemApp = systemAppPrefixes.contains { bundleURL.path.hasPrefix($0) }
                || (signature.teamIdentifier.map(Self.isAppleTeamIdentifier) ?? false)
            let sizeOnDisk = reader.sizeOnDisk(bundleURL: bundleURL)

            let info = AppInfo(
                bundleID: metadata.bundleID,
                name: metadata.name,
                displayName: metadata.displayName,
                shortVersion: metadata.shortVersion,
                bundleVersion: metadata.bundleVersion,
                bundlePath: metadata.bundlePath,
                executablePath: metadata.executablePath,
                installDate: metadata.installDate,
                lastUsedDate: metadata.lastUsedDate,
                isRunning: isRunning,
                isSystemApp: isSystemApp,
                sizeOnDisk: sizeOnDisk,
                teamIdentifier: signature.teamIdentifier,
                signatureValid: signature.valid
            )

            // Dedup: first-seen wins, so non-system search roots (e.g. /Applications)
            // take precedence over paths surfaced by NSRunningApplication.
            if byBundleID[metadata.bundleID] == nil {
                byBundleID[metadata.bundleID] = info
                order.append(metadata.bundleID)
            }
        }

        return order.compactMap { byBundleID[$0] }
    }

    /// Apple uses reserved team identifiers for its own signing; the public
    /// code signature reports them as such on system binaries.
    private static func isAppleTeamIdentifier(_ teamID: String) -> Bool {
        teamID == "Software Signing" || teamID == "Apple Software"
    }
}
