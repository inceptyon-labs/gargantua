import Foundation

public struct CloudAIRecommendation: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct CloudAIDeepAnalysis: Sendable, Equatable {
    public let summary: String
    public let recommendations: [CloudAIRecommendation]
    public let rawText: String
    public let usageCostCents: Int

    public init(
        summary: String,
        recommendations: [CloudAIRecommendation],
        rawText: String,
        usageCostCents: Int
    ) {
        self.summary = summary
        self.recommendations = recommendations
        self.rawText = rawText
        self.usageCostCents = usageCostCents
    }
}

public struct CloudCleanupPlan: Sendable {
    public let targetBytes: Int64
    public let proposedItems: [ScanResult]
    public let proposedBytes: Int64
    public let rationale: String
    public let usageCostCents: Int

    public init(
        targetBytes: Int64,
        proposedItems: [ScanResult],
        proposedBytes: Int64,
        rationale: String,
        usageCostCents: Int
    ) {
        self.targetBytes = targetBytes
        self.proposedItems = proposedItems
        self.proposedBytes = proposedBytes
        self.rationale = rationale
        self.usageCostCents = usageCostCents
    }
}

public struct CloudDuplicateResolutionSuggestion: Codable, Sendable, Equatable {
    public let groupID: String
    public let keepID: String
    public let deleteIDs: [String]
    public let rationale: String

    public init(groupID: String, keepID: String, deleteIDs: [String], rationale: String) {
        self.groupID = groupID
        self.keepID = keepID
        self.deleteIDs = deleteIDs
        self.rationale = rationale
    }
}

public struct CloudScanRuleSuggestionResult: Sendable, Equatable {
    public let proposedRulesURL: URL
    public let yaml: String
    public let rationale: String
    public let usageCostCents: Int

    public init(
        proposedRulesURL: URL,
        yaml: String,
        rationale: String,
        usageCostCents: Int
    ) {
        self.proposedRulesURL = proposedRulesURL
        self.yaml = yaml
        self.rationale = rationale
        self.usageCostCents = usageCostCents
    }
}

@MainActor
public final class CloudAIService: ObservableObject {
    @Published public private(set) var isRunning = false

    private let configurationStore: CloudAIConfigurationStore
    private let keyStore: any CloudAPIKeyStore
    private let transport: any CloudAITransport
    private let usageLedger: CloudAIUsageLedger
    private let logger: CloudAIRequestLogger
    private let fileManager: FileManager
    private let contentProvider: CloudAIRedactor.ContentProvider?

    public init(
        configurationStore: CloudAIConfigurationStore = CloudAIConfigurationStore(),
        keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore(),
        transport: any CloudAITransport = AnthropicMessagesTransport(),
        usageLedger: CloudAIUsageLedger = CloudAIUsageLedger(),
        logger: CloudAIRequestLogger = CloudAIRequestLogger(),
        fileManager: FileManager = .default,
        contentProvider: CloudAIRedactor.ContentProvider? = nil
    ) {
        self.configurationStore = configurationStore
        self.keyStore = keyStore
        self.transport = transport
        self.usageLedger = usageLedger
        self.logger = logger
        self.fileManager = fileManager
        self.contentProvider = contentProvider
    }

    public func saveAPIKey(_ apiKey: String) throws {
        try keyStore.save(apiKey)
    }

    public func revokeAPIKey() throws {
        try keyStore.delete()
    }

    public func status() async -> CloudAIStatus {
        await CloudAIStatusProvider.snapshot(
            configurationStore: configurationStore,
            keyStore: keyStore,
            usageLedger: usageLedger
        )
    }

    public func deepAnalyze(results: [ScanResult]) async throws -> CloudAIDeepAnalysis {
        let configuration = configurationStore.load()
        let items = try CloudAIRedactor.items(
            from: results,
            allowsFileContents: configuration.allowsFileContents,
            contentProvider: contentProvider
        )
        let prompt = try CloudAIPromptBuilder.deepAnalysisPrompt(items: items)
        let completion = try await perform(
            feature: .deepAnalysis,
            prompt: prompt,
            metadata: ["item_count": "\(items.count)"],
            configuration: configuration
        )
        let parsed = CloudAIJSONExtractor.decode(
            DeepAnalysisPayload.self,
            from: completion.response.text
        )
        let summary = parsed?.summary ?? completion.response.text
        let recommendations = (parsed?.recommendations ?? []).map(CloudAIRecommendation.init(text:))
        return CloudAIDeepAnalysis(
            summary: summary,
            recommendations: recommendations,
            rawText: completion.response.text,
            usageCostCents: completion.actualCostCents
        )
    }

    public func proposeCleanupTarget(
        results: [ScanResult],
        targetBytes: Int64
    ) async throws -> CloudCleanupPlan {
        let configuration = configurationStore.load()
        let items = try CloudAIRedactor.items(
            from: results,
            allowsFileContents: configuration.allowsFileContents,
            contentProvider: contentProvider
        )
        let prompt = try CloudAIPromptBuilder.targetCleanupPrompt(items: items, targetBytes: targetBytes)
        let completion = try await perform(
            feature: .targetCleanup,
            prompt: prompt,
            metadata: [
                "item_count": "\(items.count)",
                "target_bytes": "\(targetBytes)",
            ],
            configuration: configuration
        )

        let parsed = CloudAIJSONExtractor.decode(TargetCleanupPayload.self, from: completion.response.text)
        let allowedIDs = Set(results.filter { $0.safety != .protected_ }.map(\.id))
        let requestedIDs = parsed?.itemIDs ?? []
        let proposedItems = requestedIDs
            .filter { allowedIDs.contains($0) }
            .compactMap { id in results.first(where: { $0.id == id }) }
        let proposedBytes = proposedItems.reduce(Int64(0)) { sum, item in
            let (next, overflow) = sum.addingReportingOverflow(item.size)
            return overflow ? Int64.max : next
        }

        return CloudCleanupPlan(
            targetBytes: targetBytes,
            proposedItems: proposedItems,
            proposedBytes: proposedBytes,
            rationale: parsed?.rationale ?? completion.response.text,
            usageCostCents: completion.actualCostCents
        )
    }

    public func resolveDuplicates(
        groups: [DuplicateGroup]
    ) async throws -> [CloudDuplicateResolutionSuggestion] {
        let configuration = configurationStore.load()
        let inputs = try groups.map {
            try CloudAIDuplicateGroupInput(group: $0, allowsFileContents: false)
        }
        let prompt = try CloudAIPromptBuilder.duplicateResolutionPrompt(groups: inputs)
        let completion = try await perform(
            feature: .duplicateResolution,
            prompt: prompt,
            metadata: ["group_count": "\(groups.count)"],
            configuration: configuration
        )

        let parsed = CloudAIJSONExtractor.decode(DuplicateResolutionPayload.self, from: completion.response.text)
        guard let parsed else {
            return []
        }

        let protectedIDs = Set(groups.flatMap(\.files).filter { $0.safety == .protected_ }.map(\.id))
        return parsed.suggestions.map {
            CloudDuplicateResolutionSuggestion(
                groupID: $0.groupID,
                keepID: $0.keepID,
                deleteIDs: $0.deleteIDs.filter { !protectedIDs.contains($0) },
                rationale: $0.rationale
            )
        }
    }

    public func suggestScanRules(
        from results: [ScanResult],
        proposedRulesURL: URL? = nil
    ) async throws -> CloudScanRuleSuggestionResult {
        let targetURL = proposedRulesURL ?? Self.defaultProposedRulesURL(fileManager: fileManager)
        guard Self.isProposedRulesURLAllowed(targetURL) else {
            throw CloudAIError.liveRuleWriteDenied
        }

        let configuration = configurationStore.load()
        let items = try CloudAIRedactor.items(
            from: results,
            allowsFileContents: configuration.allowsFileContents,
            contentProvider: contentProvider
        )
        let prompt = try CloudAIPromptBuilder.scanRuleSuggestionPrompt(items: items)
        let completion = try await perform(
            feature: .scanRuleSuggestion,
            prompt: prompt,
            metadata: ["item_count": "\(items.count)"],
            configuration: configuration
        )

        let parsed = CloudAIJSONExtractor.decode(ScanRuleSuggestionPayload.self, from: completion.response.text)
        let yaml = parsed?.yaml ?? completion.response.text
        let body = """
        # Proposed Gargantua cleanup rules
        # Generated by Cloud AI. Review before promoting to live bundled rules.

        \(yaml)
        """

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: targetURL, atomically: true, encoding: .utf8)

        return CloudScanRuleSuggestionResult(
            proposedRulesURL: targetURL,
            yaml: yaml,
            rationale: parsed?.rationale ?? "Cloud AI proposed rules for review.",
            usageCostCents: completion.actualCostCents
        )
    }

    private func perform(
        feature: CloudAIFeature,
        prompt: String,
        metadata: [String: String],
        configuration: CloudAIConfiguration
    ) async throws -> (response: CloudAIResponse, actualCostCents: Int) {
        guard configuration.isEnabled else {
            throw CloudAIError.disabled
        }
        guard let apiKey = try keyStore.read() else {
            throw CloudAIError.missingAPIKey
        }

        let request = CloudAIRequest(
            feature: feature,
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            userPrompt: prompt,
            metadata: metadata
        )
        let inputEstimate = CloudAICostEstimator.estimateTokens(for: request.systemPrompt + request.userPrompt)
        let estimatedCost = CloudAICostEstimator.estimateCents(
            inputTokens: inputEstimate,
            outputTokens: request.maxTokens
        )
        let usage = await usageLedger.snapshot()
        guard usage.spentCents + estimatedCost <= configuration.monthlySpendCapCents else {
            throw CloudAIError.monthlyCapExceeded(
                estimatedCents: estimatedCost,
                capCents: configuration.monthlySpendCapCents,
                spentCents: usage.spentCents
            )
        }

        isRunning = true
        defer { isRunning = false }

        do {
            let response = try await transport.complete(request, apiKey: apiKey)
            let actualCost = CloudAICostEstimator.estimateCents(
                inputTokens: response.inputTokens == 0 ? inputEstimate : response.inputTokens,
                outputTokens: response.outputTokens
            )
            await usageLedger.record(costCents: actualCost)
            try await logger.append(CloudAIRequestLogEntry(
                feature: feature,
                model: configuration.model,
                estimatedCostCents: estimatedCost,
                actualCostCents: actualCost,
                inputTokens: response.inputTokens,
                outputTokens: response.outputTokens,
                status: "success",
                metadata: metadata,
                requestID: response.requestID
            ))
            return (response, actualCost)
        } catch {
            try? await logger.append(CloudAIRequestLogEntry(
                feature: feature,
                model: configuration.model,
                estimatedCostCents: estimatedCost,
                actualCostCents: 0,
                inputTokens: inputEstimate,
                outputTokens: 0,
                status: "failed",
                metadata: metadata,
                requestID: nil
            ))
            throw error
        }
    }

    public static func defaultProposedRulesURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Gargantua", isDirectory: true)
            .appendingPathComponent("proposed-rules", isDirectory: true)
            .appendingPathComponent("cloud-ai-proposed-rules.yaml")
    }

    public static func isProposedRulesURLAllowed(_ url: URL) -> Bool {
        let components = Set(url.standardizedFileURL.pathComponents)
        return !components.contains("cleanup_rules") && !components.contains("uninstall_rules")
    }
}
