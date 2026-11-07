import Foundation
import Security
import Testing
@testable import GargantuaLicensing

/// Storage whose writes always fail — simulates a keychain save error.
final class FailingLicenseReceiptStorage: LicenseReceiptStorage, @unchecked Sendable {
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws {
        throw KeychainLicenseStorageError(status: errSecIO)
    }
    func delete() throws {}
}

@Suite("LicenseStore")
struct LicenseStoreTests {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-licensing-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json", isDirectory: false)
    }

    private func makeStore(
        storage: any LicenseReceiptStorage = InMemoryLicenseReceiptStorage(),
        legacyFileURL: URL? = nil,
        migrationMarker: any LicenseMigrationMarker = InMemoryLicenseMigrationMarker(),
        client: MockPolarClient,
        grace: TimeInterval = LicensePolarConfig.validationGraceInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> LicenseStore {
        LicenseStore(
            storage: storage,
            legacyFileURL: legacyFileURL,
            migrationMarker: migrationMarker,
            client: client,
            graceInterval: grace,
            now: now,
            deviceLabel: { "Test Mac" }
        )
    }

    private func writeLegacyReceipt(to url: URL, status: LicenseKeyStatus = .granted) throws {
        let receipt = LicenseReceipt(
            key: "GARG-LEGACY", activationId: "act-legacy", email: "old@user.com", name: "Old User",
            status: status, activatedAt: Date(), lastValidated: Date()
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(receipt).write(to: url)
    }

    @Test("Activate stores a granted receipt with the returned activation id")
    func activatePersistsReceipt() async throws {
        let client = MockPolarClient(
            activateResult: .success(
                PolarActivation(activationId: "act-xyz", status: .granted, email: "paid@user.com", name: "Paid User")
            )
        )
        let store = makeStore(client: client)

        let receipt = try await store.activate(key: "  GARG-ABCD  ")

        #expect(client.activateCount == 1)
        #expect(receipt.key == "GARG-ABCD") // trimmed
        #expect(receipt.activationId == "act-xyz")
        #expect(receipt.email == "paid@user.com")
        #expect(receipt.status == .granted)
        #expect(store.loadCachedReceipt()?.activationId == "act-xyz")
    }

    @Test("Activation limit reached surfaces as a typed error")
    func activateLimitReached() async {
        let client = MockPolarClient(activateResult: .failure(.activationLimitReached))
        let store = makeStore(client: client)

        await #expect(throws: PolarLicenseError.activationLimitReached) {
            try await store.activate(key: "GARG-FULL")
        }
        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Failed local save rolls back the server activation slot")
    func activateRollsBackWhenSaveFails() async {
        let client = MockPolarClient()
        let store = makeStore(storage: FailingLicenseReceiptStorage(), client: client)

        await #expect(throws: LicenseStoreError.self) {
            try await store.activate(key: "GARG-1")
        }
        // The just-consumed slot is freed so the user can retry safely.
        #expect(client.deactivateCount == 1)
        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Fresh granted receipt is currently valid; stale one is not")
    func graceWindow() throws {
        let store = makeStore(client: MockPolarClient(), grace: 100)

        let fresh = LicenseReceipt(
            key: "K", activationId: "A", email: nil, name: nil,
            status: .granted, activatedAt: Date(timeIntervalSince1970: 0),
            lastValidated: Date(timeIntervalSince1970: 1000)
        )
        // 50s later — within 100s grace
        #expect(store.isCurrentlyValid(fresh, at: Date(timeIntervalSince1970: 1050)))
        // 150s later — past grace
        #expect(!store.isCurrentlyValid(fresh, at: Date(timeIntervalSince1970: 1150)))
    }

    @Test("Validation stamp in the future (clock moved backward) is not valid")
    func backdatedClockNotValid() {
        let store = makeStore(client: MockPolarClient(), grace: 10_000)
        let validated = Date(timeIntervalSince1970: 1_750_000_000)
        let receipt = LicenseReceipt(
            key: "K", activationId: "A", email: nil, name: nil,
            status: .granted, activatedAt: validated, lastValidated: validated
        )
        // Clock rolled back a day before the last validation — reject.
        #expect(!store.isCurrentlyValid(receipt, at: validated.addingTimeInterval(-24 * 60 * 60)))
        // Small skew within tolerance stays valid.
        #expect(store.isCurrentlyValid(receipt, at: validated.addingTimeInterval(-60)))
    }

    @Test("Revoked status is never currently valid even within grace")
    func revokedNotValid() {
        let store = makeStore(client: MockPolarClient(), grace: 10_000)
        let revoked = LicenseReceipt(
            key: "K", activationId: "A", email: nil, name: nil,
            status: .revoked, activatedAt: Date(), lastValidated: Date()
        )
        #expect(!store.isCurrentlyValid(revoked))
    }

    @Test("Revalidate refreshes the timestamp on granted")
    func revalidateRefreshes() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let client = MockPolarClient()
        let store = makeStore(client: client, now: { clock.now })
        try await store.activate(key: "GARG-1")
        clock.now = Date(timeIntervalSince1970: 5000)

        let updated = try await store.revalidate()

        #expect(client.validateCount == 1)
        #expect(client.lastValidatedActivationId == "act-1")
        #expect(updated?.lastValidated == Date(timeIntervalSince1970: 5000))
    }

    @Test("Revalidate clears the cache when the server reports revoked")
    func revalidateClearsOnRevoked() async throws {
        let client = MockPolarClient()
        let store = makeStore(client: client)
        try await store.activate(key: "GARG-1")

        client.validateResult = .success(PolarValidation(status: .revoked, email: nil, name: nil))
        let result = try await store.revalidate()

        #expect(result == nil)
        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Revalidate clears the cache on 404 (stale activation)")
    func revalidateClearsOnNotFound() async throws {
        let client = MockPolarClient()
        let store = makeStore(client: client)
        try await store.activate(key: "GARG-1")

        client.validateResult = .failure(.notFound)
        let result = try await store.revalidate()

        #expect(result == nil)
        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Revalidate clears the cache when the key turns out to belong to another product")
    func revalidateClearsOnWrongProduct() async throws {
        let client = MockPolarClient()
        let store = makeStore(client: client)
        try await store.activate(key: "GARG-1")

        client.validateResult = .failure(.wrongProduct)
        let result = try await store.revalidate()

        #expect(result == nil)
        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Revalidate keeps the cache when the network is down (offline grace)")
    func revalidateKeepsCacheOffline() async throws {
        let client = MockPolarClient()
        let store = makeStore(client: client)
        try await store.activate(key: "GARG-1")

        client.validateResult = .failure(.network("offline"))
        await #expect(throws: PolarLicenseError.network("offline")) {
            try await store.revalidate()
        }
        // Cache survives so offline grace still applies.
        #expect(store.loadCachedReceipt() != nil)
    }

    @Test("Deactivate calls the server and clears the cache")
    func deactivateClears() async throws {
        let client = MockPolarClient()
        let store = makeStore(client: client)
        try await store.activate(key: "GARG-1")

        try await store.deactivate()

        #expect(client.deactivateCount == 1)
        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Deactivate still clears the cache when the server call fails")
    func deactivateClearsEvenOnError() async throws {
        let client = MockPolarClient(deactivateError: .network("offline"))
        let store = makeStore(client: client)
        try await store.activate(key: "GARG-1")

        try await store.deactivate()

        #expect(store.loadCachedReceipt() == nil)
    }

    @Test("Empty storage returns nil")
    func emptyStorageReturnsNil() {
        let store = makeStore(client: MockPolarClient())
        #expect(store.loadCachedReceipt() == nil)
    }

    // MARK: - Legacy license.json migration

    @Test("Legacy license.json migrates to storage once, then the file is deleted")
    func legacyReceiptMigrates() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeLegacyReceipt(to: url)
        let storage = InMemoryLicenseReceiptStorage()
        let marker = InMemoryLicenseMigrationMarker()
        let store = makeStore(storage: storage, legacyFileURL: url, migrationMarker: marker, client: MockPolarClient())

        let receipt = store.loadCachedReceipt()

        #expect(receipt?.key == "GARG-LEGACY")
        #expect(receipt?.activationId == "act-legacy")
        #expect(marker.isDone())
        #expect(try storage.read() != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Hand-crafted license.json after migration does not yield a receipt")
    func forgedLegacyFileIgnoredAfterMigration() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeLegacyReceipt(to: url) // the "forged" file
        let store = makeStore(
            legacyFileURL: url,
            migrationMarker: InMemoryLicenseMigrationMarker(done: true),
            client: MockPolarClient()
        )

        #expect(store.loadCachedReceipt() == nil)
        // The forged file isn't consumed either — it's simply never trusted.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("First launch without a legacy file marks migration done")
    func missingLegacyFileMarksMigrationDone() {
        let marker = InMemoryLicenseMigrationMarker()
        let store = makeStore(legacyFileURL: tempFileURL(), migrationMarker: marker, client: MockPolarClient())

        #expect(store.loadCachedReceipt() == nil)
        #expect(marker.isDone())
    }

    @Test("Failed keychain write during migration fails closed and retries next launch")
    func legacyMigrationWriteFailureFailsClosed() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeLegacyReceipt(to: url)
        let marker = InMemoryLicenseMigrationMarker()
        let store = makeStore(
            storage: FailingLicenseReceiptStorage(),
            legacyFileURL: url,
            migrationMarker: marker,
            client: MockPolarClient()
        )

        // Fail closed: an unpersistable receipt is NOT honored — a forged
        // license.json can't grant a licensed session just because the
        // keychain write fails.
        #expect(store.loadCachedReceipt() == nil)
        // File + marker survive so a launch with a healthy keychain migrates it.
        #expect(!marker.isDone())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Keychain receipt wins over a lingering legacy file")
    func storageWinsOverLegacyFile() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeLegacyReceipt(to: url)
        let client = MockPolarClient()
        let store = makeStore(legacyFileURL: url, client: client)
        try await store.activate(key: "GARG-FRESH")

        #expect(store.loadCachedReceipt()?.key == "GARG-FRESH")
    }
}
