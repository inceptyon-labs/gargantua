import Foundation
import Security

public protocol TrialClockStorage: Sendable {
    func readFirstLaunchDate() -> Date?
    func writeFirstLaunchDate(_ date: Date)
    /// Discards the stored stamp. Defaults to a no-op for stores where it has
    /// no meaning; the migrating store uses it to retire the legacy key.
    func clear()
}

public extension TrialClockStorage {
    func clear() {}
}

/// Reads from `primary`, falling back once to `legacy` and adopting its value.
///
/// This is what retires the resettable plaintext trial stamp. A mid-trial user
/// upgrading from the `UserDefaults` build keeps their original start date
/// (rather than the trial restarting at a fresh 14 days) because the first read
/// migrates the legacy value into `primary` and clears the legacy key, so the
/// plaintext stamp is no longer authoritative and a later `defaults delete`
/// does nothing.
public struct MigratingTrialClockStorage: TrialClockStorage {
    private let primary: any TrialClockStorage
    private let legacy: any TrialClockStorage

    public init(primary: any TrialClockStorage, legacy: any TrialClockStorage) {
        self.primary = primary
        self.legacy = legacy
    }

    public func readFirstLaunchDate() -> Date? {
        if let date = primary.readFirstLaunchDate() {
            return date
        }
        guard let migrated = legacy.readFirstLaunchDate() else {
            return nil
        }
        primary.writeFirstLaunchDate(migrated)
        legacy.clear()
        return migrated
    }

    public func writeFirstLaunchDate(_ date: Date) {
        primary.writeFirstLaunchDate(date)
    }

    public func clear() {
        primary.clear()
        legacy.clear()
    }
}

/// Device-only Keychain storage for the trial's first-launch stamp.
///
/// The plain `UserDefaults` stamp it replaces can be reset with a single
/// `defaults delete com.gargantua.licensing.trial.firstLaunch`, restarting the
/// 14-day trial at will. A Keychain item can't be rewritten without the app's
/// signing identity, so a casual reset no longer works. Same trust domain and
/// accessibility as `KeychainLicenseReceiptStorage`
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — never synced).
///
/// The date is stored as its `timeIntervalSince1970` in a UTF-8 string, so the
/// stored form is a stable, self-describing scalar rather than an archiver blob.
public struct KeychainTrialClockStorage: TrialClockStorage {
    private let service: String
    private let account: String

    public init(
        service: String = "com.gargantua.licensing",
        account: String = "trial-first-launch"
    ) {
        self.service = service
        self.account = account
    }

    public func readFirstLaunchDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              let epoch = TimeInterval(string)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    public func writeFirstLaunchDate(_ date: Date) {
        let data = Data(String(date.timeIntervalSince1970).utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        if SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }
        let query = lookup.merging(attributes) { _, new in new }
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

public final class UserDefaultsTrialClockStorage: TrialClockStorage, @unchecked Sendable {
    public static let firstLaunchKey = "com.gargantua.licensing.trial.firstLaunch"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func readFirstLaunchDate() -> Date? {
        defaults.object(forKey: Self.firstLaunchKey) as? Date
    }

    public func writeFirstLaunchDate(_ date: Date) {
        defaults.set(date, forKey: Self.firstLaunchKey)
    }

    /// Removes the legacy plaintext stamp. Called once after the Keychain store
    /// adopts the value, so the resettable key is no longer authoritative.
    public func clear() {
        defaults.removeObject(forKey: Self.firstLaunchKey)
    }
}

public final class InMemoryTrialClockStorage: TrialClockStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDate: Date?

    public init(initialDate: Date? = nil) {
        self.storedDate = initialDate
    }

    public func readFirstLaunchDate() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedDate
    }

    public func writeFirstLaunchDate(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        storedDate = date
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storedDate = nil
    }
}

public final class TrialClock: @unchecked Sendable {
    public static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    private let storage: any TrialClockStorage
    private let now: @Sendable () -> Date

    public init(
        storage: any TrialClockStorage = MigratingTrialClockStorage(
            primary: KeychainTrialClockStorage(),
            legacy: UserDefaultsTrialClockStorage()
        ),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.now = now
    }

    @discardableResult
    public func firstLaunchDate() -> Date {
        if let existing = storage.readFirstLaunchDate() { return existing }
        let current = now()
        storage.writeFirstLaunchDate(current)
        return current
    }

    public func daysRemaining() -> Int {
        // Seed the launch date first so any clock motion during seeding counts
        // as elapsed time, not as a negative interval that would inflate the
        // ceiling math.
        let launch = firstLaunchDate()
        // A clock moved behind the recorded launch date reads as negative
        // elapsed time; clamp so backdating never mints more than the full
        // trial window.
        let elapsed = max(0, now().timeIntervalSince(launch))
        let remaining = Self.trialDuration - elapsed
        if remaining <= 0 { return 0 }
        return Int(ceil(remaining / (24 * 60 * 60)))
    }

    public func isExpired() -> Bool {
        daysRemaining() == 0
    }
}
