import Foundation

// MARK: - Models

/// One human-readable Cloud AI recommendation line.
public struct CloudAIRecommendation: Codable, Sendable, Equatable {
    /// Recommendation text returned by the model.
    public let text: String

    /// Creates a recommendation wrapping the supplied text.
    public init(text: String) {
        self.text = text
    }
}

/// Parsed deep-analysis output for a set of scan results.
public struct CloudAIDeepAnalysis: Sendable, Equatable {
    /// One-paragraph human-readable analysis summary.
    public let summary: String
    /// Structured recommendations parsed from the model output.
    public let recommendations: [CloudAIRecommendation]
    /// Raw model text retained for fallback rendering.
    public let rawText: String
    /// Estimated request cost, in cents.
    public let usageCostCents: Int

    /// Creates a deep-analysis result.
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

/// Cloud-proposed cleanup plan targeting a specific reclaim size.
public struct CloudCleanupPlan: Sendable {
    /// Reclaim target requested by the caller, in bytes.
    public let targetBytes: Int64
    /// Items the model recommends cleaning, filtered against protected items.
    public let proposedItems: [ScanResult]
    /// Total bytes covered by the proposed items.
    public let proposedBytes: Int64
    /// Free-text rationale for the proposed plan.
    public let rationale: String
    /// Estimated request cost, in cents.
    public let usageCostCents: Int

    /// Creates a cleanup plan.
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

/// Cloud-proposed resolution for one duplicate group.
public struct CloudDuplicateResolutionSuggestion: Codable, Sendable, Equatable {
    /// Identifier of the duplicate group the suggestion applies to.
    public let groupID: String
    /// Identifier of the file the model recommends keeping.
    public let keepID: String
    /// Identifiers of files the model recommends removing.
    public let deleteIDs: [String]
    /// Free-text rationale for the suggestion.
    public let rationale: String

    /// Creates a duplicate-resolution suggestion.
    public init(groupID: String, keepID: String, deleteIDs: [String], rationale: String) {
        self.groupID = groupID
        self.keepID = keepID
        self.deleteIDs = deleteIDs
        self.rationale = rationale
    }
}

/// Result of a Cloud AI scan-rule suggestion request.
public struct CloudScanRuleSuggestionResult: Sendable, Equatable {
    /// File URL where the proposed rules YAML was written.
    public let proposedRulesURL: URL
    /// YAML body of the proposed rules.
    public let yaml: String
    /// Free-text rationale for the proposed rules.
    public let rationale: String
    /// Estimated request cost, in cents.
    public let usageCostCents: Int

    /// Creates a scan-rule suggestion result.
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

// MARK: - Feature methods

extension CloudAIService {
    /// Runs a deep analysis over the supplied scan results.
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

    /// Asks the model for a cleanup plan that targets a specific reclaim size.
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

    /// Asks the model to recommend keep/delete decisions for duplicate groups.
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

    /// Asks the model to draft new cleanup rules and writes them to a proposed-rules file.
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

    /// Default URL for cloud-proposed rule files in user-scoped Application Support.
    public static func defaultProposedRulesURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Gargantua", isDirectory: true)
            .appendingPathComponent("proposed-rules", isDirectory: true)
            .appendingPathComponent("cloud-ai-proposed-rules.yaml")
    }

    /// Returns whether the supplied URL is outside live bundled rule directories.
    public static func isProposedRulesURLAllowed(_ url: URL) -> Bool {
        let components = Set(url.standardizedFileURL.pathComponents)
        return !components.contains("cleanup_rules") && !components.contains("uninstall_rules")
    }
}
