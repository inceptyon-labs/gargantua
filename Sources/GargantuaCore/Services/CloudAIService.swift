import Foundation

/// High-level Cloud AI workflow service backing the in-app feature surface.
@MainActor
public final class CloudAIService: ObservableObject {
    /// Whether a Cloud AI request is currently in flight.
    @Published public private(set) var isRunning = false

    let configurationStore: CloudAIConfigurationStore
    private let keyStore: any CloudAPIKeyStore
    private let transport: any CloudAITransport
    private let usageLedger: CloudAIUsageLedger
    private let logger: CloudAIRequestLogger
    let fileManager: FileManager
    let contentProvider: CloudAIRedactor.ContentProvider?

    /// Creates a service with injected configuration, transport, and usage dependencies.
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

    /// Stores an Anthropic API key in the keychain.
    public func saveAPIKey(_ apiKey: String) throws {
        try keyStore.save(apiKey)
    }

    /// Removes the stored Anthropic API key from the keychain.
    public func revokeAPIKey() throws {
        try keyStore.delete()
    }

    /// Returns the combined Cloud AI readiness and usage status.
    public func status() async -> CloudAIStatus {
        await CloudAIStatusProvider.snapshot(
            configurationStore: configurationStore,
            keyStore: keyStore,
            usageLedger: usageLedger
        )
    }

    func perform(
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
}
