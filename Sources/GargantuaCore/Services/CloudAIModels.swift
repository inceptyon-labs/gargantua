import Foundation

/// Cloud AI workflows that can issue model requests.
public enum CloudAIFeature: String, Codable, Sendable, CaseIterable {
    /// Deep analysis for selected scan results.
    case deepAnalysis = "deep_analysis"
    /// Targeted cleanup advice for a specific item or group.
    case targetCleanup = "target_cleanup"
    /// Duplicate-file resolution recommendations.
    case duplicateResolution = "duplicate_resolution"
    /// Suggestions for new or improved cleanup rules.
    case scanRuleSuggestion = "scan_rule_suggestion"
    /// File-organization proposals for cluttered user folders.
    case fileOrganization = "file_organization"
    /// Deeper, on-demand explanation of a single scan result.
    case explanation = "explanation"
}

/// Which API the Cloud engine talks to. Anthropic uses the native Messages
/// API; `openAICompatible` uses the OpenAI Chat Completions shape, which a
/// configurable base URL points at OpenAI itself *or* any compatible endpoint
/// (OpenRouter, Groq, Together, Ollama, LM Studio, llama.cpp, …).
public enum CloudAIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible = "openai_compatible"

    public var id: String { rawValue }

    /// User-facing provider name.
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    /// Default model identifier when switching to this provider.
    public var defaultModel: String {
        switch self {
        case .anthropic: CloudAIConfiguration.defaultModel
        case .openAICompatible: "gpt-4o-mini"
        }
    }

    /// Default `/v1`-style base URL. Empty for Anthropic (it uses a fixed
    /// Messages endpoint, not a configurable base).
    public var defaultBaseURL: String {
        switch self {
        case .anthropic: ""
        case .openAICompatible: "https://api.openai.com/v1"
        }
    }
}

/// User-configurable Cloud AI settings.
public struct CloudAIConfiguration: Codable, Sendable, Equatable {
    /// Default Anthropic model used for cloud requests.
    public static let defaultModel = "claude-sonnet-4-6"
    /// Default monthly spend cap, in cents.
    public static let defaultMonthlySpendCapCents = 500
    /// Default maximum output token budget for Cloud AI responses.
    public static let defaultMaxTokens = 1_200

    /// Whether Cloud AI features are enabled.
    public var isEnabled: Bool
    /// Whether prompts may include file contents instead of metadata only.
    public var allowsFileContents: Bool
    /// Monthly spend limit, in cents. Enforced for Anthropic only — for
    /// OpenAI-compatible endpoints pricing varies per provider/model (and many
    /// local ones are free), so billing is left to the provider.
    public var monthlySpendCapCents: Int
    /// Model identifier used for requests.
    public var model: String
    /// Maximum output tokens requested from the model.
    public var maxTokens: Int
    /// Which API to talk to.
    public var provider: CloudAIProvider
    /// Base URL for the OpenAI-compatible endpoint (e.g.
    /// `https://api.openai.com/v1`). Ignored when `provider == .anthropic`.
    public var openAIBaseURL: String

    /// Creates a Cloud AI configuration, clamping numeric limits to valid ranges.
    public init(
        isEnabled: Bool = false,
        allowsFileContents: Bool = false,
        monthlySpendCapCents: Int = Self.defaultMonthlySpendCapCents,
        model: String = Self.defaultModel,
        maxTokens: Int = Self.defaultMaxTokens,
        provider: CloudAIProvider = .anthropic,
        openAIBaseURL: String = ""
    ) {
        self.isEnabled = isEnabled
        self.allowsFileContents = allowsFileContents
        self.monthlySpendCapCents = max(0, monthlySpendCapCents)
        self.model = model
        self.maxTokens = max(1, maxTokens)
        self.provider = provider
        self.openAIBaseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, allowsFileContents, monthlySpendCapCents, model, maxTokens, provider, openAIBaseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            allowsFileContents: try c.decodeIfPresent(Bool.self, forKey: .allowsFileContents) ?? false,
            monthlySpendCapCents: try c.decodeIfPresent(Int.self, forKey: .monthlySpendCapCents) ?? Self.defaultMonthlySpendCapCents,
            model: try c.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel,
            maxTokens: try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? Self.defaultMaxTokens,
            provider: try c.decodeIfPresent(CloudAIProvider.self, forKey: .provider) ?? .anthropic,
            openAIBaseURL: try c.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? ""
        )
    }

    /// Resolved OpenAI-compatible base URL, falling back to OpenAI's when the
    /// user hasn't set one. `nil` only when a non-empty value can't form a URL.
    public var resolvedOpenAIBaseURL: URL? {
        let trimmed = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? CloudAIProvider.openAICompatible.defaultBaseURL : trimmed
        return URL(string: value)
    }

    /// True when the OpenAI-compatible endpoint uses plain HTTP to a non-local
    /// host — the API key and any file snippets would travel unencrypted. LAN
    /// and loopback hosts are fine (local-first setups), so they don't trip it.
    public var usesInsecureRemoteEndpoint: Bool {
        guard provider == .openAICompatible,
              let url = resolvedOpenAIBaseURL,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased()
        else { return false }
        return !Self.isLocalOrPrivateHost(host)
    }

    /// Loopback, `.local`, and RFC 1918 private ranges — addresses where plain
    /// HTTP stays on the user's own machine or LAN.
    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255
        let octets = host.split(separator: ".")
        if octets.count == 4, octets[0] == "172", let second = Int(octets[1]), (16 ... 31).contains(second) {
            return true
        }
        return false
    }
}

/// Thread-safe persistence wrapper for `CloudAIConfiguration`.
public final class CloudAIConfigurationStore: @unchecked Sendable {
    /// UserDefaults key used for the encoded configuration.
    public static let defaultsKey = "cloudAIConfiguration"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Creates a configuration store backed by the supplied defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads the saved configuration, or returns defaults when none is available.
    public func load() -> CloudAIConfiguration {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(CloudAIConfiguration.self, from: data)
        else {
            return CloudAIConfiguration()
        }
        return decoded
    }

    /// Saves the supplied configuration when it can be encoded.
    public func save(_ configuration: CloudAIConfiguration) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Monthly usage counters for Cloud AI requests.
public struct CloudAIUsageSnapshot: Codable, Sendable, Equatable {
    /// Calendar month identifier in `yyyy-MM` form.
    public let monthIdentifier: String
    /// Total spend recorded for the month, in cents.
    public let spentCents: Int
    /// Number of requests recorded for the month.
    public let requestCount: Int
    /// Timestamp of the most recent Cloud AI request.
    public let lastRun: Date?

    /// Creates a usage snapshot, clamping counters to non-negative values.
    public init(
        monthIdentifier: String,
        spentCents: Int = 0,
        requestCount: Int = 0,
        lastRun: Date? = nil
    ) {
        self.monthIdentifier = monthIdentifier
        self.spentCents = max(0, spentCents)
        self.requestCount = max(0, requestCount)
        self.lastRun = lastRun
    }
}

/// Actor that maintains monthly Cloud AI usage in user defaults.
public actor CloudAIUsageLedger {
    /// UserDefaults key used for the encoded usage snapshot.
    public static let defaultsKey = "cloudAIUsageSnapshot"

    private let defaults: UserDefaults
    private let calendar: Calendar

    /// Creates a usage ledger backed by the supplied defaults and calendar.
    public init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// Loads the current-month usage snapshot, resetting stale months automatically.
    public func snapshot(now: Date = Date()) -> CloudAIUsageSnapshot {
        let currentMonth = Self.monthIdentifier(for: now, calendar: calendar)
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(CloudAIUsageSnapshot.self, from: data),
              decoded.monthIdentifier == currentMonth
        else {
            let fresh = CloudAIUsageSnapshot(monthIdentifier: currentMonth)
            save(fresh)
            return fresh
        }
        return decoded
    }

    @discardableResult
    /// Records a completed request cost and returns the updated monthly snapshot.
    public func record(costCents: Int, now: Date = Date()) -> CloudAIUsageSnapshot {
        let current = snapshot(now: now)
        let updated = CloudAIUsageSnapshot(
            monthIdentifier: current.monthIdentifier,
            spentCents: current.spentCents + max(0, costCents),
            requestCount: current.requestCount + 1,
            lastRun: now
        )
        save(updated)
        return updated
    }

    /// Formats a date as the ledger month identifier.
    public static func monthIdentifier(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    private func save(_ snapshot: CloudAIUsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Combined readiness and usage status for Cloud AI settings UI.
public struct CloudAIStatus: Sendable, Equatable {
    /// Whether Cloud AI features are enabled.
    public let isEnabled: Bool
    /// Whether an API key is available.
    public let hasAPIKey: Bool
    /// Whether prompts may include file contents.
    public let allowsFileContents: Bool
    /// Configured monthly cap, in cents.
    public let monthlySpendCapCents: Int
    /// Spend recorded in the current month, in cents.
    public let spentCents: Int
    /// Requests recorded in the current month.
    public let requestCount: Int
    /// Timestamp of the last recorded Cloud AI request.
    public let lastRun: Date?
    /// Configured model identifier.
    public let model: String

    /// Creates a Cloud AI status snapshot.
    public init(
        isEnabled: Bool,
        hasAPIKey: Bool,
        allowsFileContents: Bool,
        monthlySpendCapCents: Int,
        spentCents: Int,
        requestCount: Int,
        lastRun: Date?,
        model: String
    ) {
        self.isEnabled = isEnabled
        self.hasAPIKey = hasAPIKey
        self.allowsFileContents = allowsFileContents
        self.monthlySpendCapCents = monthlySpendCapCents
        self.spentCents = spentCents
        self.requestCount = requestCount
        self.lastRun = lastRun
        self.model = model
    }
}

/// Factory for combined Cloud AI status snapshots.
public enum CloudAIStatusProvider {
    /// Loads configuration, key presence, and usage into a single status value.
    public static func snapshot(
        configurationStore: CloudAIConfigurationStore = CloudAIConfigurationStore(),
        keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore(),
        usageLedger: CloudAIUsageLedger = CloudAIUsageLedger()
    ) async -> CloudAIStatus {
        let configuration = configurationStore.load()
        let usage = await usageLedger.snapshot()
        let hasKey = (try? keyStore.hasKey()) ?? false
        return CloudAIStatus(
            isEnabled: configuration.isEnabled,
            hasAPIKey: hasKey,
            allowsFileContents: configuration.allowsFileContents,
            monthlySpendCapCents: configuration.monthlySpendCapCents,
            spentCents: usage.spentCents,
            requestCount: usage.requestCount,
            lastRun: usage.lastRun,
            model: configuration.model
        )
    }
}

/// Errors surfaced by Cloud AI request preparation, transport, and parsing.
public enum CloudAIError: Error, LocalizedError, Equatable {
    /// Cloud AI is disabled in settings.
    case disabled
    /// No Anthropic API key is available.
    case missingAPIKey
    /// The configured API key does not match the expected format.
    case invalidAPIKey
    /// The estimated request would exceed the monthly spend cap.
    case monthlyCapExceeded(estimatedCents: Int, capCents: Int, spentCents: Int)
    /// A request attempted to write directly to live cleanup rules.
    case liveRuleWriteDenied
    /// The model returned no text.
    case emptyResponse
    /// The model returned text that could not be parsed for the requested feature.
    case invalidResponse(String)
    /// The HTTP transport failed with a status code and response message.
    case transport(statusCode: Int, message: String)

    /// Localized user-facing error description.
    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Cloud analysis is disabled."
        case .missingAPIKey:
            return "Add an Anthropic API key before using cloud analysis."
        case .invalidAPIKey:
            return "The Anthropic API key format is invalid."
        case .monthlyCapExceeded(let estimated, let cap, let spent):
            return "Cloud analysis would exceed the monthly cap. Estimated \(estimated)c, spent \(spent)c, cap \(cap)c."
        case .liveRuleWriteDenied:
            return "Cloud AI suggestions can only be written to proposed rule files."
        case .emptyResponse:
            return "Cloud AI returned an empty response."
        case .invalidResponse(let message):
            return message
        case .transport(let statusCode, let message):
            return "Cloud AI request failed with HTTP \(statusCode): \(message)"
        }
    }
}

/// Lightweight token and cost estimator for Anthropic Cloud AI requests.
public enum CloudAICostEstimator {
    /// Input price for Claude Sonnet requests, in cents per million tokens.
    public static let sonnetInputCentsPerMillionTokens = 300
    /// Output price for Claude Sonnet requests, in cents per million tokens.
    public static let sonnetOutputCentsPerMillionTokens = 1_500

    /// Estimates token count from UTF-8 byte length.
    public static func estimateTokens(for text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }

    /// Estimates total request cost in cents for input and output token counts.
    public static func estimateCents(inputTokens: Int, outputTokens: Int) -> Int {
        let input = Double(max(0, inputTokens)) * Double(sonnetInputCentsPerMillionTokens) / 1_000_000.0
        let output = Double(max(0, outputTokens)) * Double(sonnetOutputCentsPerMillionTokens) / 1_000_000.0
        return max(1, Int(ceil(input + output)))
    }
}

/// Prepared Cloud AI request payload before transport-specific encoding.
public struct CloudAIRequest: Sendable, Equatable {
    /// Feature workflow associated with the request.
    public let feature: CloudAIFeature
    /// Model identifier to request.
    public let model: String
    /// Maximum output tokens requested.
    public let maxTokens: Int
    /// System prompt sent to the model.
    public let systemPrompt: String
    /// User prompt sent to the model.
    public let userPrompt: String
    /// Extra non-sensitive request metadata for logging or auditing.
    public let metadata: [String: String]

    /// Creates a Cloud AI request, clamping the output token budget to at least one.
    public init(
        feature: CloudAIFeature,
        model: String,
        maxTokens: Int,
        systemPrompt: String = CloudAIPromptBuilder.systemPrompt,
        userPrompt: String,
        metadata: [String: String] = [:]
    ) {
        self.feature = feature
        self.model = model
        self.maxTokens = max(1, maxTokens)
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.metadata = metadata
    }
}

/// Parsed Cloud AI response with token accounting metadata.
public struct CloudAIResponse: Sendable, Equatable {
    /// Text returned by the model.
    public let text: String
    /// Input token count reported or estimated for the request.
    public let inputTokens: Int
    /// Output token count reported or estimated for the response.
    public let outputTokens: Int
    /// Provider request identifier when available.
    public let requestID: String?

    /// Creates a Cloud AI response, clamping token counts to non-negative values.
    public init(
        text: String,
        inputTokens: Int,
        outputTokens: Int,
        requestID: String? = nil
    ) {
        self.text = text
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.requestID = requestID
    }
}
