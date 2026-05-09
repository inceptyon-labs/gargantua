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

    /// Drop any cached identities. Callers that drive long-lived inventory
    /// passes (Background Items review pane, scheduled scans) should call this
    /// at the start of each pass so a replaced binary doesn't keep its prior
    /// trusted classification. Default no-op for stateless implementations.
    func clearCache()
}

extension BinaryIdentityResolving {
    public func clearCache() {}
}

/// Default implementation. Caches results per binary path because `codesign`
/// is slow at scale (the launchd item index can easily walk hundreds of
/// distinct binaries on a developer machine).
///
/// The cache is unbounded — instances are intended to live for the duration
/// of a single inventory pass, not across long-running app sessions. Call
/// `clearCache()` between passes if reusing.
public final class DefaultBinaryIdentityResolver: BinaryIdentityResolving, @unchecked Sendable {
    private let bundleReader: AppBundleReading
    private let signatureVerifier: any DetailedCodeSignatureVerifying
    private let registry: KnownVendorRegistry

    private let cacheLock = NSLock()
    private var cache: [String: BinaryIdentity] = [:]

    public init(
        bundleReader: AppBundleReading = DefaultAppBundleReader(),
        signatureVerifier: any DetailedCodeSignatureVerifying = DefaultCodeSignatureVerifier(),
        registry: KnownVendorRegistry = .default
    ) {
        self.bundleReader = bundleReader
        self.signatureVerifier = signatureVerifier
        self.registry = registry
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

        // Only surface the registry entry's display name and sensitive
        // categories when the binary actually passed the anchor check that
        // gates `.thirdPartyKnown`. A spoofed Team ID on an ad-hoc-signed
        // binary lands in `.unsigned`; in that case we must not propagate any
        // claim derived from a registry hit.
        let trustedRegistryEntry = (vendor == .thirdPartyKnown) ? registryEntry : nil

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
            vendorDisplayName: trustedRegistryEntry?.displayName,
            sensitiveCategories: trustedRegistryEntry?.sensitiveCategories ?? []
        )
    }

    /// Returns the nearest `.app`, `.framework`, `.appex`, `.systemextension`,
    /// `.xpc`, or `.bundle` ancestor of `binaryPath` — or `binaryPath` itself
    /// when it already names such a bundle (the case for SMAppService /
    /// `sfltool dumpbtm` records that surface the bundle URL directly rather
    /// than the executable inside it). Returns `nil` if the binary lives
    /// outside any bundle (e.g. `/usr/local/bin/foo`).
    ///
    /// `.systemextension` matters for endpoint security and VPN agents which
    /// commonly ship as system extensions and are flagged sensitive.
    func enclosingBundleURL(for binaryPath: String) -> URL? {
        let bundleExtensions: Set<String> = ["app", "framework", "appex", "systemextension", "xpc", "bundle"]
        let start = URL(fileURLWithPath: binaryPath).standardizedFileURL
        if bundleExtensions.contains(start.pathExtension) {
            return start
        }
        var current = start
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

        // For third-party classification we require BOTH a valid signature AND
        // an Apple-generic anchor — without the anchor check, an ad-hoc/self-
        // signed binary that happens to embed a Team ID-shaped string in its
        // signing dict could spoof its way to `.thirdPartyKnown`.
        guard details.valid == true,
              details.isAppleGenericAnchor,
              details.teamIdentifier != nil
        else {
            return .unsigned
        }

        if registryEntry != nil {
            return .thirdPartyKnown
        }
        return .thirdPartyUnknown
    }
}
