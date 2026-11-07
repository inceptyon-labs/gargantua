import Foundation

public enum LicenseStoreError: Error, Sendable, Equatable {
    case persistenceFailed(String)
}

/// Persists the Polar license activation locally and brokers activate /
/// revalidate / deactivate against `PolarLicenseValidating`. Reads are sync
/// (keychain-cached receipt) so the license gate never blocks on the network;
/// the `validate` round-trip happens in the background to extend the offline
/// grace window and catch revocations.
public final class LicenseStore: @unchecked Sendable {
    /// Clock skew tolerated before a `lastValidated` in the future — i.e. a
    /// clock moved backward — invalidates the cached receipt. Keeps a
    /// backdated clock from extending offline grace indefinitely; the next
    /// successful revalidation heals the stamp.
    public static let clockSkewTolerance: TimeInterval = 60 * 60

    private let storage: any LicenseReceiptStorage
    private let legacyFileURL: URL?
    private let migrationMarker: any LicenseMigrationMarker
    private let client: any PolarLicenseValidating
    private let graceInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let deviceLabel: @Sendable () -> String
    private let lock = NSLock()

    public convenience init() {
        self.init(
            storage: KeychainLicenseReceiptStorage(),
            client: PolarLicenseClient()
        )
    }

    public init(
        storage: any LicenseReceiptStorage,
        legacyFileURL: URL? = LicenseStore.legacyFileURL,
        migrationMarker: any LicenseMigrationMarker = KeychainLicenseMigrationMarker(),
        client: any PolarLicenseValidating,
        graceInterval: TimeInterval = LicensePolarConfig.validationGraceInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        deviceLabel: @escaping @Sendable () -> String = { LicenseStore.defaultDeviceLabel() }
    ) {
        self.storage = storage
        self.legacyFileURL = legacyFileURL
        self.migrationMarker = migrationMarker
        self.client = client
        self.graceInterval = graceInterval
        self.now = now
        self.deviceLabel = deviceLabel
    }

    /// Where pre-keychain builds cached the receipt as plain JSON. Only read
    /// during the one-shot migration; new receipts never touch disk.
    public static var legacyFileURL: URL {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Gargantua", isDirectory: true)
        return supportDir.appendingPathComponent("license.json", isDirectory: false)
    }

    public static func defaultDeviceLabel() -> String {
        Host.current().localizedName ?? "Mac"
    }

    // MARK: - Cache reads (sync)

    public func loadCachedReceipt() -> LicenseReceipt? {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? storage.read(),
           let receipt = try? JSONDecoder().decode(LicenseReceipt.self, from: data) {
            return receipt
        }
        return migrateLegacyReceipt()
    }

    /// Trusts the legacy `license.json` exactly once — the first launch after
    /// upgrading — moving it into the keychain with no re-activation and no
    /// prompt. The marker means a hand-crafted JSON file dropped there later
    /// is ignored instead of "migrated" into licensed status.
    private func migrateLegacyReceipt() -> LicenseReceipt? {
        guard !migrationMarker.isDone(), let legacyFileURL else { return nil }
        guard let data = try? Data(contentsOf: legacyFileURL),
              let receipt = try? JSONDecoder().decode(LicenseReceipt.self, from: data)
        else {
            migrationMarker.markDone()
            return nil
        }
        do {
            try storage.write(data)
        } catch {
            // Fail closed: if we can't persist to the keychain, do NOT honor
            // the receipt. Honoring an unpersistable receipt would make the
            // on-disk JSON the de-facto store — the exact forgery vector this
            // hardening removes. Leave the file and marker untouched so a
            // launch with a healthy keychain migrates it properly.
            return nil
        }
        migrationMarker.markDone()
        try? FileManager.default.removeItem(at: legacyFileURL)
        return receipt
    }

    /// A cached receipt is currently valid if it's `granted` and the last
    /// server validation is within the grace window — and not in the future,
    /// which would mean the clock was moved backward.
    public func isCurrentlyValid(_ receipt: LicenseReceipt, at reference: Date? = nil) -> Bool {
        guard receipt.status == .granted else { return false }
        let ref = reference ?? now()
        let sinceValidation = ref.timeIntervalSince(receipt.lastValidated)
        return sinceValidation >= -Self.clockSkewTolerance && sinceValidation < graceInterval
    }

    // MARK: - Network operations

    @discardableResult
    public func activate(key rawKey: String) async throws -> LicenseReceipt {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let activation = try await client.activate(
            key: key,
            label: deviceLabel(),
            meta: Self.defaultMeta()
        )
        let stamp = now()
        let receipt = LicenseReceipt(
            key: key,
            activationId: activation.activationId,
            email: activation.email,
            name: activation.name,
            status: activation.status,
            activatedAt: stamp,
            lastValidated: stamp
        )
        do {
            try save(receipt)
        } catch {
            // The server already consumed an activation slot; free it so a
            // retry doesn't burn through the activation limit while this Mac
            // stays unlicensed.
            try? await client.deactivate(key: key, activationId: activation.activationId)
            throw error
        }
        return receipt
    }

    /// Re-checks the cached license against the server. On `granted`, refreshes
    /// the validation timestamp (extending offline grace). On revoked/disabled,
    /// 404 (key gone, stale activation) or a key for another product, clears
    /// the cache. Network errors
    /// propagate without touching the cache so offline grace still applies.
    @discardableResult
    public func revalidate() async throws -> LicenseReceipt? {
        guard let cached = loadCachedReceipt() else { return nil }
        do {
            let result = try await client.validate(key: cached.key, activationId: cached.activationId)
            if result.status == .granted {
                let updated = cached.revalidated(
                    status: .granted,
                    email: result.email,
                    name: result.name,
                    at: now()
                )
                try save(updated)
                return updated
            }
            try clear()
            return nil
        } catch PolarLicenseError.notFound {
            try clear()
            return nil
        } catch PolarLicenseError.wrongProduct {
            try clear()
            return nil
        }
    }

    public func deactivate() async throws {
        if let cached = loadCachedReceipt() {
            // Best-effort: free the server slot. Even if the network call
            // fails, drop the local cache so the Mac stops claiming a license.
            try? await client.deactivate(key: cached.key, activationId: cached.activationId)
        }
        try clear()
    }

    // MARK: - Persistence

    public func save(_ receipt: LicenseReceipt) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try JSONEncoder().encode(receipt)
            try storage.write(data)
        } catch {
            throw LicenseStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try storage.delete()
        } catch {
            throw LicenseStoreError.persistenceFailed(error.localizedDescription)
        }
        if let legacyFileURL {
            try? FileManager.default.removeItem(at: legacyFileURL)
        }
    }

    private static func defaultMeta() -> [String: String] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return [
            "app_version": version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }
}
