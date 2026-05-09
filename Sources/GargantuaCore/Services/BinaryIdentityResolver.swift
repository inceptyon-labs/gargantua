import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "BinaryIdentityResolver")

/// Resolves a binary path on disk to a fully-populated `BinaryIdentity`.
///
/// Walks up from `Foo.app/Contents/MacOS/foo` (or any nested helper) to the
/// nearest enclosing bundle, reads its Info.plist, evaluates its code
/// signature, and classifies the vendor against `KnownVendorRegistry`.
public protocol BinaryIdentityResolving: Sendable {
    /// Returns a resolved identity for `binaryPath`. Implementations should
    /// always return a value — when nothing can be determined, the returned
    /// identity has `vendor == .unsigned` and most fields are `nil`.
    func resolve(binaryPath: String) -> BinaryIdentity
}

/// Default implementation. Caches results per binary path because `codesign`
/// is slow at scale (the launchd item index can easily walk hundreds of
/// distinct binaries on a developer machine).
public final class DefaultBinaryIdentityResolver: BinaryIdentityResolving, @unchecked Sendable {
    private let bundleReader: AppBundleReading
    private let signatureVerifier: any DetailedCodeSignatureVerifying
    private let registry: KnownVendorRegistry
    private let fileManager: FileManager

    private let cacheLock = NSLock()
    private var cache: [String: BinaryIdentity] = [:]

    public init(
        bundleReader: AppBundleReading = DefaultAppBundleReader(),
        signatureVerifier: any DetailedCodeSignatureVerifying = DefaultCodeSignatureVerifier(),
        registry: KnownVendorRegistry = .default,
        fileManager: FileManager = .default
    ) {
        self.bundleReader = bundleReader
        self.signatureVerifier = signatureVerifier
        self.registry = registry
        self.fileManager = fileManager
    }

    public func resolve(binaryPath: String) -> BinaryIdentity {
        if let cached = cachedIdentity(for: binaryPath) {
            return cached
        }
        let identity = computeIdentity(for: binaryPath)
        storeCachedIdentity(identity, for: binaryPath)
        return identity
    }

    /// Drops the cache. Test helper.
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Cache

    private func cachedIdentity(for path: String) -> BinaryIdentity? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[path]
    }

    private func storeCachedIdentity(_ identity: BinaryIdentity, for path: String) {
        cacheLock.lock()
        cache[path] = identity
        cacheLock.unlock()
    }

    // MARK: - Resolution

    private func computeIdentity(for binaryPath: String) -> BinaryIdentity {
        let bundleURL = enclosingBundleURL(for: binaryPath)
        let metadata = bundleURL.flatMap { bundleReader.readMetadata(bundleURL: $0) }

        // For signature verification, prefer the bundle when available because
        // SecStaticCode's evaluation is bundle-aware (Mach-O slices, embedded
        // requirements, nested code). Fall back to the raw binary path so
        // standalone executables under `/usr/local/bin/` still get a verdict.
        let signatureURL = bundleURL ?? URL(fileURLWithPath: binaryPath)
        let details = signatureVerifier.verifyDetails(bundleURL: signatureURL)

        let registryEntry = registry.lookup(
            teamIdentifier: details.teamIdentifier,
            bundleIdentifier: metadata?.bundleID
        )
        let vendor = classifyVendor(details: details, registryEntry: registryEntry)

        if let bundleURL {
            logger.debug(
                "Resolved \(binaryPath, privacy: .public) → bundle \(bundleURL.path, privacy: .public), vendor \(vendor.rawValue, privacy: .public)"
            )
        } else {
            logger.debug(
                "Resolved \(binaryPath, privacy: .public) → no bundle, vendor \(vendor.rawValue, privacy: .public)"
            )
        }

        return BinaryIdentity(
            binaryPath: binaryPath,
            bundlePath: bundleURL?.path,
            bundleIdentifier: metadata?.bundleID,
            bundleName: metadata?.name,
            bundleShortVersion: metadata?.shortVersion,
            teamIdentifier: details.teamIdentifier,
            signingIdentity: details.signingIdentity,
            signatureValid: details.valid,
            isNotarized: details.isNotarized,
            vendor: vendor,
            vendorDisplayName: registryEntry?.displayName,
            sensitiveCategories: registryEntry?.sensitiveCategories ?? []
        )
    }

    /// Walks up the path looking for the nearest `.app`, `.framework`, `.appex`,
    /// `.xpc`, or `.bundle` ancestor. Returns `nil` if the binary lives outside
    /// any bundle (e.g. `/usr/local/bin/foo`, `/opt/homebrew/bin/bar`).
    func enclosingBundleURL(for binaryPath: String) -> URL? {
        let bundleExtensions: Set<String> = ["app", "framework", "appex", "xpc", "bundle"]
        var current = URL(fileURLWithPath: binaryPath).standardizedFileURL
        // Cap at a reasonable depth to avoid pathological symlink loops.
        for _ in 0 ..< 32 {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            if bundleExtensions.contains(parent.pathExtension) {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func classifyVendor(
        details: CodeSignatureDetails,
        registryEntry: KnownVendorEntry?
    ) -> VendorClassification {
        // `anchor apple` matches Apple-shipped first-party binaries; `anchor
        // apple generic` is more permissive and also matches Developer ID-signed
        // binaries. So an Apple binary satisfies both, but a Developer ID
        // binary only satisfies the latter.
        if details.valid == true, details.isAppleAnchor {
            return .apple
        }

        // Without a valid signature *and* a Team ID we can't reliably
        // distinguish third-party-known from third-party-unknown.
        guard details.valid == true, details.teamIdentifier != nil else {
            return .unsigned
        }

        if registryEntry != nil {
            return .thirdPartyKnown
        }
        return .thirdPartyUnknown
    }
}
