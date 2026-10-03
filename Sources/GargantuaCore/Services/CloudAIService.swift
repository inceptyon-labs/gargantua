import Foundation

/// High-level Cloud AI workflow service backing the in-app feature surface.
@MainActor
public final class CloudAIService: ObservableObject {
    /// Whether a Cloud AI request is currently in flight.
    @Published public private(set) var isRunning = false

    let configurationStore: CloudAIConfigurationStore
    private let keyStoreOverride: (any CloudAPIKeyStore)?
    private let transportOverride: (any CloudAITransport)?
    private let usageLedger: CloudAIUsageLedger
    private let logger: CloudAIRequestLogger
    let fileManager: FileManager
    let contentProvider: CloudAIRedactor.ContentProvider?

    /// Creates a service with injected configuration, transport, and usage dependencies.
    /// `transport` and `keyStore` are test overrides; when nil they're resolved
    /// per request from the configured provider (Anthropic vs OpenAI-compatible).
    public init(
        configurationStore: CloudAIConfigurationStore = CloudAIConfigurationStore(),
        keyStore: (any CloudAPIKeyStore)? = nil,
        transport: (any CloudAITransport)? = nil,
        usageLedger: CloudAIUsageLedger = CloudAIUsageLedger(),
        logger: CloudAIRequestLogger = CloudAIRequestLogger(),
        fileManager: FileManager = .default,
        contentProvider: CloudAIRedactor.ContentProvider? = nil
    ) {
        self.configurationStore = configurationStore
        self.keyStoreOverride = keyStore
        self.transportOverride = transport
        self.usageLedger = usageLedger
        self.logger = logger
        self.fileManager = fileManager
        self.contentProvider = contentProvider
    }

    /// Keychain store for `provider`, honoring a test override.
    func keyStore(for configuration: CloudAIConfiguration) -> any CloudAPIKeyStore {
        keyStoreOverride ?? CloudAPIKeyStores.store(for: configuration)
    }

    /// Transport for the configured provider, honoring a test override.
    private func transport(for configuration: CloudAIConfiguration) -> any CloudAITransport {
        transportOverride ?? CloudAITransportFactory.make(for: configuration)
    }

    /// Stores an API key for the active provider in the keychain.
    public func saveAPIKey(_ apiKey: String) throws {
        try keyStore(for: configurationStore.load()).save(apiKey)
    }

    /// Removes the stored API key for the active provider from the keychain.
    public func revokeAPIKey() throws {
        try keyStore(for: configurationStore.load()).delete()
    }

    /// Returns the combined Cloud AI readiness and usage status.
    public func status() async -> CloudAIStatus {
        await CloudAIStatusProvider.snapshot(
            configurationStore: configurationStore,
            keyStore: keyStore(for: configurationStore.load()),
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

        // Anthropic requires a key; OpenAI-compatible may not (local servers
        // like Ollama ignore auth), so a missing key there means "send none".
        let provider = configuration.provider
        let storedKey = try keyStore(for: configuration).read()
        let apiKey: String
        if provider == .anthropic {
            guard let key = storedKey else { throw CloudAIError.missingAPIKey }
            apiKey = key
        } else {
            apiKey = storedKey ?? ""
        }

        let request = CloudAIRequest(
            feature: feature,
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            userPrompt: prompt,
            metadata: metadata
        )
        let inputEstimate = CloudAICostEstimator.estimateTokens(for: request.systemPrompt + request.userPrompt)
        // The cost estimator is Anthropic-priced; only Anthropic is metered and
        // capped here. OpenAI-compatible billing is left to the provider.
        let isMetered = provider == .anthropic
        let estimatedCost = isMetered
            ? CloudAICostEstimator.estimateCents(inputTokens: inputEstimate, outputTokens: request.maxTokens)
            : 0
        if isMetered {
            let usage = await usageLedger.snapshot()
            guard usage.spentCents + estimatedCost <= configuration.monthlySpendCapCents else {
                throw CloudAIError.monthlyCapExceeded(
                    estimatedCents: estimatedCost,
                    capCents: configuration.monthlySpendCapCents,
                    spentCents: usage.spentCents
                )
            }
        }

        isRunning = true
        defer { isRunning = false }

        do {
            let response = try await transport(for: configuration).complete(request, apiKey: apiKey)
            let actualCost = isMetered
                ? CloudAICostEstimator.estimateCents(
                    inputTokens: response.inputTokens == 0 ? inputEstimate : response.inputTokens,
                    outputTokens: response.outputTokens
                )
                : 0
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
