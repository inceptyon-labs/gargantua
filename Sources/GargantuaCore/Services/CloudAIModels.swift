import Foundation

public enum CloudAIFeature: String, Codable, Sendable, CaseIterable {
    case deepAnalysis = "deep_analysis"
    case targetCleanup = "target_cleanup"
    case duplicateResolution = "duplicate_resolution"
    case scanRuleSuggestion = "scan_rule_suggestion"

    public var displayName: String {
        switch self {
        case .deepAnalysis: "Deep analysis"
        case .targetCleanup: "Target cleanup"
        case .duplicateResolution: "Duplicate resolution"
        case .scanRuleSuggestion: "Scan-rule suggestions"
        }
    }
}

public struct CloudAIConfiguration: Codable, Sendable, Equatable {
    public static let defaultModel = "claude-sonnet-4-20250514"
    public static let defaultMonthlySpendCapCents = 500
    public static let defaultMaxTokens = 1_200

    public var isEnabled: Bool
    public var allowsFileContents: Bool
    public var monthlySpendCapCents: Int
    public var model: String
    public var maxTokens: Int

    public init(
        isEnabled: Bool = false,
        allowsFileContents: Bool = false,
        monthlySpendCapCents: Int = Self.defaultMonthlySpendCapCents,
        model: String = Self.defaultModel,
        maxTokens: Int = Self.defaultMaxTokens
    ) {
        self.isEnabled = isEnabled
        self.allowsFileContents = allowsFileContents
        self.monthlySpendCapCents = max(0, monthlySpendCapCents)
        self.model = model
        self.maxTokens = max(1, maxTokens)
    }
}

public final class CloudAIConfigurationStore: @unchecked Sendable {
    public static let defaultsKey = "cloudAIConfiguration"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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

    public func save(_ configuration: CloudAIConfiguration) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public struct CloudAIUsageSnapshot: Codable, Sendable, Equatable {
    public let monthIdentifier: String
    public let spentCents: Int
    public let requestCount: Int
    public let lastRun: Date?

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

    public func remainingCents(capCents: Int) -> Int {
        max(0, capCents - spentCents)
    }
}

public actor CloudAIUsageLedger {
    public static let defaultsKey = "cloudAIUsageSnapshot"

    private let defaults: UserDefaults
    private let calendar: Calendar

    public init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

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

    public func canSpend(_ estimatedCents: Int, capCents: Int, now: Date = Date()) -> Bool {
        let current = snapshot(now: now)
        return current.spentCents + max(0, estimatedCents) <= capCents
    }

    @discardableResult
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

    public func reset(now: Date = Date()) {
        save(CloudAIUsageSnapshot(monthIdentifier: Self.monthIdentifier(for: now, calendar: calendar)))
    }

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

public struct CloudAIStatus: Sendable, Equatable {
    public let isEnabled: Bool
    public let hasAPIKey: Bool
    public let allowsFileContents: Bool
    public let monthlySpendCapCents: Int
    public let spentCents: Int
    public let requestCount: Int
    public let lastRun: Date?
    public let model: String

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

    public var isReady: Bool {
        isEnabled && hasAPIKey
    }

    public var remainingCents: Int {
        max(0, monthlySpendCapCents - spentCents)
    }
}

public enum CloudAIStatusProvider {
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

public enum CloudAIError: Error, LocalizedError, Equatable {
    case disabled
    case missingAPIKey
    case invalidAPIKey
    case monthlyCapExceeded(estimatedCents: Int, capCents: Int, spentCents: Int)
    case liveRuleWriteDenied
    case emptyResponse
    case invalidResponse(String)
    case transport(statusCode: Int, message: String)

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

public enum CloudAICostEstimator {
    public static let sonnetInputCentsPerMillionTokens = 300
    public static let sonnetOutputCentsPerMillionTokens = 1_500

    public static func estimateTokens(for text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }

    public static func estimateCents(inputTokens: Int, outputTokens: Int) -> Int {
        let input = Double(max(0, inputTokens)) * Double(sonnetInputCentsPerMillionTokens) / 1_000_000.0
        let output = Double(max(0, outputTokens)) * Double(sonnetOutputCentsPerMillionTokens) / 1_000_000.0
        return max(1, Int(ceil(input + output)))
    }
}

public struct CloudAIRequest: Sendable, Equatable {
    public let feature: CloudAIFeature
    public let model: String
    public let maxTokens: Int
    public let systemPrompt: String
    public let userPrompt: String
    public let metadata: [String: String]

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

public struct CloudAIResponse: Sendable, Equatable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestID: String?

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
