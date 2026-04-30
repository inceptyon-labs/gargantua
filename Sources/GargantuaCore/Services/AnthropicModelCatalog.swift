import Foundation
import OSLog

private let catalogLogger = Logger(subsystem: "com.gargantua.core", category: "AnthropicModelCatalog")

/// One Anthropic model surfaced by the public `/v1/models` API.
///
/// Both the `id` (machine-readable, what we pass to `claude --model`) and the
/// optional `displayName` (human-readable label like "Claude Sonnet 4.6")
/// come straight from the API. `createdAt` lets us sort newest-first.
public struct AnthropicModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String?
    public let createdAt: Date?

    public init(id: String, displayName: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

/// Origin of a model list — drives the "fetched live"/"using offline list"
/// hint in the picker so users know whether the list might be stale.
public enum AnthropicModelCatalogSource: Sendable, Equatable {
    /// Just fetched from `/v1/models`.
    case live
    /// Loaded from disk cache that's still within TTL.
    case cacheFresh(writtenAt: Date)
    /// Cache existed but was older than TTL — surfaced because the live fetch
    /// also failed (offline, rate-limited, key revoked, etc).
    case cacheStale(writtenAt: Date)
    /// Built-in fallback list. Either no API key is configured or the fetch
    /// failed and there was no cache to fall back on.
    case bakedIn
}

/// Result of `AnthropicModelCatalog.loadModels(...)`. Always non-nil — the
/// catalog falls back through cache → baked-in list so the picker always
/// has something to show.
public struct AnthropicModelCatalogResult: Sendable, Equatable {
    public let models: [AnthropicModel]
    public let source: AnthropicModelCatalogSource

    public init(models: [AnthropicModel], source: AnthropicModelCatalogSource) {
        self.models = models
        self.source = source
    }
}

/// HTTP-level fetcher abstraction so tests can swap in canned responses
/// without spinning a real URLSession.
public protocol AnthropicModelsFetching: Sendable {
    func fetch(apiKey: String) async throws -> [AnthropicModel]
}

/// Default fetcher: hits `https://api.anthropic.com/v1/models`, follows
/// pagination via `last_id` / `after_id`, and caps at five pages defensively
/// (Anthropic ships < 50 models in practice — 5×100 is plenty of headroom).
public struct AnthropicModelsAPIClient: AnthropicModelsFetching {
    public let baseURL: URL
    public let anthropicVersion: String
    public let session: URLSession
    public let maxPages: Int

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        anthropicVersion: String = "2023-06-01",
        session: URLSession = .shared,
        maxPages: Int = 5
    ) {
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
        self.session = session
        self.maxPages = max(1, maxPages)
    }

    public func fetch(apiKey: String) async throws -> [AnthropicModel] {
        var collected: [AnthropicModel] = []
        var afterID: String?
        for _ in 0 ..< maxPages {
            let page = try await fetchPage(apiKey: apiKey, afterID: afterID)
            collected.append(contentsOf: page.data)
            guard page.hasMore, let last = page.lastID else { break }
            afterID = last
        }
        return collected
    }

    private struct PageEnvelope: Decodable {
        let data: [AnthropicModel]
        let hasMore: Bool
        let lastID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    private func fetchPage(apiKey: String, afterID: String?) async throws -> PageEnvelope {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "100")]
        if let afterID {
            components?.queryItems?.append(URLQueryItem(name: "after_id", value: afterID))
        }
        guard let url = components?.url else {
            throw AnthropicModelCatalogError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicModelCatalogError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicModelCatalogError.httpStatus(http.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PageEnvelope.self, from: data)
    }
}

public enum AnthropicModelCatalogError: Error, LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Could not build /v1/models request URL."
        case .invalidResponse: "Anthropic API returned a non-HTTP response."
        case .httpStatus(let status, let message):
            "Anthropic /v1/models returned HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

/// Stateful catalog that combines a live fetcher, an on-disk cache, and a
/// hard-coded fallback list. The agent UI calls `loadModels(...)` and gets
/// back a non-empty list every time — even with no API key configured and no
/// network — so the picker is always populated.
public final class AnthropicModelCatalog: @unchecked Sendable {
    /// Models we ship in the binary so a fresh install with no API key still
    /// shows useful choices. Picked from the system-prompt model lineup at
    /// the time of writing; the live fetcher overrides this whenever it
    /// succeeds.
    public static let bakedInModels: [AnthropicModel] = [
        AnthropicModel(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
        AnthropicModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        AnthropicModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
    ]

    /// Picked so a user who opens the app once a day sees fresh model names
    /// without paying a network round-trip on every settings render.
    public static let defaultCacheTTL: TimeInterval = 24 * 60 * 60

    private let fetcher: any AnthropicModelsFetching
    private let keyStore: any CloudAPIKeyStore
    private let cacheURL: URL
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    public init(
        fetcher: any AnthropicModelsFetching = AnthropicModelsAPIClient(),
        keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore(),
        cacheURL: URL = AnthropicModelCatalog.defaultCacheURL(),
        cacheTTL: TimeInterval = AnthropicModelCatalog.defaultCacheTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.fetcher = fetcher
        self.keyStore = keyStore
        self.cacheURL = cacheURL
        self.cacheTTL = cacheTTL
        self.now = now
        self.fileManager = fileManager
    }

    /// Resolve the model list, using a fresh disk cache when possible,
    /// falling back through the live API → stale cache → baked-in defaults.
    /// Set `forceRefresh: true` from the picker's "Refresh" button to skip
    /// the cache shortcut and re-hit the API.
    public func loadModels(forceRefresh: Bool = false) async -> AnthropicModelCatalogResult {
        if !forceRefresh, let cached = readFreshCache() {
            return AnthropicModelCatalogResult(models: cached.models, source: .cacheFresh(writtenAt: cached.writtenAt))
        }

        let key: String?
        do {
            key = try keyStore.read()
        } catch {
            catalogLogger.warning("AnthropicModelCatalog: keychain read failed — \(error.localizedDescription, privacy: .public)")
            key = nil
        }

        guard let apiKey = key, !apiKey.isEmpty else {
            if let stale = readAnyCache() {
                return AnthropicModelCatalogResult(models: stale.models, source: .cacheStale(writtenAt: stale.writtenAt))
            }
            return AnthropicModelCatalogResult(models: Self.bakedInModels, source: .bakedIn)
        }

        do {
            let fresh = try await fetcher.fetch(apiKey: apiKey)
            guard !fresh.isEmpty else {
                // Treat empty page as a fetch miss; otherwise a flaky API
                // could wipe the picker for an entire TTL window.
                if let stale = readAnyCache() {
                    return AnthropicModelCatalogResult(models: stale.models, source: .cacheStale(writtenAt: stale.writtenAt))
                }
                return AnthropicModelCatalogResult(models: Self.bakedInModels, source: .bakedIn)
            }
            writeCache(models: fresh)
            return AnthropicModelCatalogResult(models: fresh, source: .live)
        } catch {
            catalogLogger.notice("AnthropicModelCatalog: live fetch failed — \(error.localizedDescription, privacy: .public)")
            if let stale = readAnyCache() {
                return AnthropicModelCatalogResult(models: stale.models, source: .cacheStale(writtenAt: stale.writtenAt))
            }
            return AnthropicModelCatalogResult(models: Self.bakedInModels, source: .bakedIn)
        }
    }

    // MARK: - Cache

    private struct CacheEnvelope: Codable {
        let writtenAt: Date
        let models: [AnthropicModel]
    }

    private func readFreshCache() -> CacheEnvelope? {
        guard let envelope = readAnyCache() else { return nil }
        return now().timeIntervalSince(envelope.writtenAt) < cacheTTL ? envelope : nil
    }

    private func readAnyCache() -> CacheEnvelope? {
        guard fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheEnvelope.self, from: data)
    }

    private func writeCache(models: [AnthropicModel]) {
        let envelope = CacheEnvelope(writtenAt: now(), models: models)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return }
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            catalogLogger.warning("AnthropicModelCatalog: cache write failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func defaultCacheURL() -> URL {
        let base: URL
        if let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            base = caches
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent("com.gargantua.core", isDirectory: true)
            .appendingPathComponent("anthropic-models.json")
    }
}
