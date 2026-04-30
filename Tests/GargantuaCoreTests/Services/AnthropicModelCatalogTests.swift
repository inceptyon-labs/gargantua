import Foundation
import Testing
@testable import GargantuaCore

@Suite("AnthropicModelCatalog")
struct AnthropicModelCatalogTests {

    // MARK: - Test doubles

    private final class StubFetcher: AnthropicModelsFetching, @unchecked Sendable {
        var result: Result<[AnthropicModel], Error>
        var lastAPIKey: String?
        var callCount = 0

        init(_ result: Result<[AnthropicModel], Error>) {
            self.result = result
        }

        func fetch(apiKey: String) async throws -> [AnthropicModel] {
            callCount += 1
            lastAPIKey = apiKey
            return try result.get()
        }
    }

    private final class StubKeyStore: CloudAPIKeyStore, @unchecked Sendable {
        var key: String?
        var readError: Error?

        init(key: String? = nil, readError: Error? = nil) {
            self.key = key
            self.readError = readError
        }

        func save(_ apiKey: String) throws { key = apiKey }
        func read() throws -> String? {
            if let readError { throw readError }
            return key
        }
        func delete() throws { key = nil }
        func hasKey() throws -> Bool { key != nil }
    }

    private struct StubError: Error, Equatable {
        let message: String
    }

    /// Each test gets its own scratch cache file so they don't trample each
    /// other when run in parallel.
    private static func scratchCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anthropic-models-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("anthropic-models.json")
    }

    private static func makeModels() -> [AnthropicModel] {
        [
            AnthropicModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6"),
            AnthropicModel(id: "claude-opus-4-7", displayName: "Opus 4.7"),
        ]
    }

    // MARK: - Tests

    @Test("loadModels returns baked-in fallback when no API key is configured and no cache exists")
    func bakedInFallbackWhenNoKey() async throws {
        let cacheURL = Self.scratchCacheURL()
        let catalog = AnthropicModelCatalog(
            fetcher: StubFetcher(.success([])),
            keyStore: StubKeyStore(key: nil),
            cacheURL: cacheURL
        )

        let result = await catalog.loadModels()
        #expect(result.source == .bakedIn)
        #expect(result.models == AnthropicModelCatalog.bakedInModels)
    }

    @Test("loadModels returns baked-in fallback when keychain read throws and no cache exists")
    func bakedInWhenKeyStoreThrows() async throws {
        let cacheURL = Self.scratchCacheURL()
        let catalog = AnthropicModelCatalog(
            fetcher: StubFetcher(.success([])),
            keyStore: StubKeyStore(readError: StubError(message: "denied")),
            cacheURL: cacheURL
        )

        let result = await catalog.loadModels()
        #expect(result.source == .bakedIn)
        #expect(result.models == AnthropicModelCatalog.bakedInModels)
    }

    @Test("loadModels hits the fetcher and writes a fresh cache when an API key is configured")
    func liveFetchWritesCache() async throws {
        let cacheURL = Self.scratchCacheURL()
        let fetcher = StubFetcher(.success(Self.makeModels()))
        let catalog = AnthropicModelCatalog(
            fetcher: fetcher,
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL
        )

        let result = await catalog.loadModels()
        #expect(result.source == .live)
        #expect(result.models.map(\.id) == ["claude-sonnet-4-6", "claude-opus-4-7"])
        #expect(fetcher.callCount == 1)
        #expect(fetcher.lastAPIKey == "sk-ant-test1234567890123456")
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("loadModels skips the fetcher and returns cacheFresh when cache is within TTL")
    func cacheFreshShortCircuit() async throws {
        let cacheURL = Self.scratchCacheURL()
        let fetcher = StubFetcher(.success(Self.makeModels()))
        let firstCall = AnthropicModelCatalog(
            fetcher: fetcher,
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL
        )
        _ = await firstCall.loadModels() // populate cache
        #expect(fetcher.callCount == 1)

        // Second catalog reuses the same cache file with TTL still active.
        let secondCall = AnthropicModelCatalog(
            fetcher: fetcher,
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL
        )
        let result = await secondCall.loadModels()

        if case .cacheFresh = result.source {
            #expect(result.models.map(\.id) == ["claude-sonnet-4-6", "claude-opus-4-7"])
            #expect(fetcher.callCount == 1, "Fresh-cache hit must not re-call the fetcher")
        } else {
            Issue.record("Expected .cacheFresh, got \(result.source)")
        }
    }

    @Test("forceRefresh re-hits the fetcher even when cache is fresh")
    func forceRefreshBypassesCache() async throws {
        let cacheURL = Self.scratchCacheURL()
        let fetcher = StubFetcher(.success(Self.makeModels()))
        let catalog = AnthropicModelCatalog(
            fetcher: fetcher,
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL
        )

        _ = await catalog.loadModels()
        let refreshed = await catalog.loadModels(forceRefresh: true)

        #expect(refreshed.source == .live)
        #expect(fetcher.callCount == 2)
    }

    @Test("loadModels falls back to stale cache when live fetch fails")
    func staleCacheFallback() async throws {
        let cacheURL = Self.scratchCacheURL()
        // Phase 1: write cache via a successful fetch with a frozen "now".
        let writeTime = Date(timeIntervalSince1970: 1_700_000_000)
        let fetcherSuccess = StubFetcher(.success(Self.makeModels()))
        let writingCatalog = AnthropicModelCatalog(
            fetcher: fetcherSuccess,
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL,
            now: { writeTime }
        )
        _ = await writingCatalog.loadModels()

        // Phase 2: advance "now" past TTL; live fetch fails; expect stale cache.
        let staleTime = writeTime.addingTimeInterval(AnthropicModelCatalog.defaultCacheTTL + 60)
        let fetcherFailing = StubFetcher(.failure(StubError(message: "offline")))
        let readingCatalog = AnthropicModelCatalog(
            fetcher: fetcherFailing,
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL,
            now: { staleTime }
        )
        let result = await readingCatalog.loadModels()

        if case .cacheStale(let writtenAt) = result.source {
            #expect(abs(writtenAt.timeIntervalSince(writeTime)) < 1)
            #expect(result.models.map(\.id) == ["claude-sonnet-4-6", "claude-opus-4-7"])
        } else {
            Issue.record("Expected .cacheStale, got \(result.source)")
        }
    }

    @Test("loadModels falls back to baked-in list when fetch fails and no cache exists")
    func bakedInFallbackWhenFetchFails() async throws {
        let cacheURL = Self.scratchCacheURL()
        let catalog = AnthropicModelCatalog(
            fetcher: StubFetcher(.failure(StubError(message: "rate limit"))),
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL
        )

        let result = await catalog.loadModels()
        #expect(result.source == .bakedIn)
        #expect(result.models == AnthropicModelCatalog.bakedInModels)
    }

    @Test("Empty fetch result does not overwrite an existing cache or wipe the picker")
    func emptyFetchPreservesCache() async throws {
        let cacheURL = Self.scratchCacheURL()
        // Seed a cache.
        let writeTime = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await AnthropicModelCatalog(
            fetcher: StubFetcher(.success(Self.makeModels())),
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL,
            now: { writeTime }
        ).loadModels()

        // Force-refresh against an empty fetch — should fall back to cache.
        let result = await AnthropicModelCatalog(
            fetcher: StubFetcher(.success([])),
            keyStore: StubKeyStore(key: "sk-ant-test1234567890123456"),
            cacheURL: cacheURL,
            now: { writeTime }
        ).loadModels(forceRefresh: true)

        // Cache is still within TTL at the same writeTime, so it surfaces as cacheStale
        // (we already pierced the cache shortcut via forceRefresh) — either kind of
        // cache hit is acceptable here as long as the picker isn't wiped.
        switch result.source {
        case .cacheFresh, .cacheStale:
            #expect(result.models.map(\.id) == ["claude-sonnet-4-6", "claude-opus-4-7"])
        default:
            Issue.record("Empty fetch should preserve the cached list, got \(result.source)")
        }
    }

    // MARK: - Configuration round-trip

    @Test("Configuration encodes and decodes selectedModel; missing field falls back to default")
    func configurationCodingRoundtrip() throws {
        let configuration = ClaudeCodeAgentConfiguration(selectedModel: "claude-haiku-4-5-20251001")
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ClaudeCodeAgentConfiguration.self, from: data)
        #expect(decoded.selectedModel == "claude-haiku-4-5-20251001")

        // Older payloads without selectedModel decode to the default.
        let legacy = #"{"isEnabled":false,"cliPath":"","maxTurns":10,"allowDestructiveMCPTools":false,"runAfterScheduledScans":false}"#
        let legacyDecoded = try JSONDecoder().decode(
            ClaudeCodeAgentConfiguration.self,
            from: Data(legacy.utf8)
        )
        #expect(legacyDecoded.selectedModel == ClaudeCodeAgentConfiguration.defaultSelectedModel)
    }
}
