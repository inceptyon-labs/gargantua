import Foundation
import Testing
@testable import GargantuaCore

@Suite("Cloud AI Tier 2")
@MainActor
struct CloudAITests {
    @Test("API key validator accepts Anthropic-shaped keys only")
    func apiKeyValidation() {
        #expect(CloudAPIKeyValidator.isPlausibleAnthropicKey("sk-ant-api03-\(String(repeating: "a", count: 32))"))
        #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey("sk-openai-not-anthropic"))
        #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey("sk-ant-api03-contains whitespace"))
        #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey("sk-ant-short"))
    }

    @Test("Redactor keeps paths and metadata but omits file content without consent")
    func redactorOmitContentWithoutConsent() throws {
        let result = makeResult(id: "safe-cache", safety: .safe)
        let items = try CloudAIRedactor.items(
            from: [result],
            allowsFileContents: false,
            contentProvider: { _ in "SECRET_FILE_CONTENTS" }
        )

        #expect(items.count == 1)
        #expect(items[0].path == result.path)
        #expect(items[0].contentPreview == nil)

        let prompt = try CloudAIPromptBuilder.deepAnalysisPrompt(items: items)
        #expect(prompt.contains(result.path))
        #expect(!prompt.contains("SECRET_FILE_CONTENTS"))
    }

    @Test("Redactor includes sanitized content only after explicit consent")
    func redactorIncludesContentWithConsent() throws {
        let items = try CloudAIRedactor.items(
            from: [makeResult(id: "review-log", safety: .review)],
            allowsFileContents: true,
            contentProvider: { _ in "first\nsecond\u{0000}third" }
        )

        #expect(items[0].contentPreview == "first second third")
    }

    @Test("Monthly cap blocks before the transport is called")
    func monthlyCapBlocksBeforeTransport() async throws {
        let defaults = try makeDefaults()
        let configStore = CloudAIConfigurationStore(defaults: defaults)
        configStore.save(CloudAIConfiguration(isEnabled: true, monthlySpendCapCents: 0))
        let transport = FakeCloudAITransport(response: CloudAIResponse(
            text: #"{"summary":"unused","recommendations":[]}"#,
            inputTokens: 10,
            outputTokens: 10
        ))

        let service = CloudAIService(
            configurationStore: configStore,
            keyStore: FakeCloudAPIKeyStore(apiKey: "sk-ant-api03-\(String(repeating: "a", count: 32))"),
            transport: transport,
            usageLedger: CloudAIUsageLedger(defaults: defaults),
            logger: CloudAIRequestLogger(logURL: tempURL("cloud-cap-log.jsonl"))
        )

        do {
            _ = try await service.deepAnalyze(results: [makeResult(id: "one", safety: .safe)])
            Issue.record("Expected monthly cap error")
        } catch CloudAIError.monthlyCapExceeded {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.callCount == 0)
    }

    @Test("Target cleanup filters protected item IDs returned by Claude")
    func targetCleanupFiltersProtectedItems() async throws {
        let defaults = try makeDefaults()
        let configStore = CloudAIConfigurationStore(defaults: defaults)
        configStore.save(CloudAIConfiguration(isEnabled: true, monthlySpendCapCents: 500))
        let logURL = tempURL("cloud-target-log.jsonl")
        let logger = CloudAIRequestLogger(logURL: logURL)
        let transport = FakeCloudAITransport(response: CloudAIResponse(
            text: #"{"item_ids":["safe","protected"],"rationale":"safe item reaches the target"}"#,
            inputTokens: 1_000,
            outputTokens: 100,
            requestID: "req_test"
        ))
        let ledger = CloudAIUsageLedger(defaults: defaults)
        let service = CloudAIService(
            configurationStore: configStore,
            keyStore: FakeCloudAPIKeyStore(apiKey: "sk-ant-api03-\(String(repeating: "b", count: 32))"),
            transport: transport,
            usageLedger: ledger,
            logger: logger
        )

        let plan = try await service.proposeCleanupTarget(
            results: [
                makeResult(id: "safe", safety: .safe, size: 1_000),
                makeResult(id: "protected", safety: .protected_, size: 9_000),
            ],
            targetBytes: 1_000
        )

        #expect(plan.proposedItems.map(\.id) == ["safe"])
        #expect(plan.proposedBytes == 1_000)
        #expect(plan.rationale == "safe item reaches the target")

        let usage = await ledger.snapshot()
        #expect(usage.requestCount == 1)
        #expect(usage.spentCents > 0)

        let entries = try await logger.entries()
        #expect(entries.count == 1)
        #expect(entries[0].feature == .targetCleanup)
        #expect(entries[0].metadata["target_bytes"] == "1000")
    }

    @Test("Scan-rule suggestions write to proposed file and reject live rule directories")
    func scanRuleSuggestionsWriteOnlyProposedFiles() async throws {
        let defaults = try makeDefaults()
        let configStore = CloudAIConfigurationStore(defaults: defaults)
        configStore.save(CloudAIConfiguration(isEnabled: true, monthlySpendCapCents: 500))
        let transport = FakeCloudAITransport(response: CloudAIResponse(
            text: #"""
            {"yaml":"rules:\n  - id: cloud_suggested_cache\n    paths: [\"~/Library/Caches/Example\"]","rationale":"repeatable cache pattern"}
            """#,
            inputTokens: 1_000,
            outputTokens: 200
        ))
        let service = CloudAIService(
            configurationStore: configStore,
            keyStore: FakeCloudAPIKeyStore(apiKey: "sk-ant-api03-\(String(repeating: "c", count: 32))"),
            transport: transport,
            usageLedger: CloudAIUsageLedger(defaults: defaults),
            logger: CloudAIRequestLogger(logURL: tempURL("cloud-rules-log.jsonl"))
        )
        let proposedURL = tempURL("proposed-rules.yaml")

        let result = try await service.suggestScanRules(
            from: [makeResult(id: "candidate", safety: .review)],
            proposedRulesURL: proposedURL
        )

        #expect(result.proposedRulesURL == proposedURL)
        let written = try String(contentsOf: proposedURL, encoding: .utf8)
        #expect(written.contains("Generated by Cloud AI"))
        #expect(written.contains("cloud_suggested_cache"))

        let liveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup_rules", isDirectory: true)
            .appendingPathComponent("live.yaml")
        await #expect(throws: CloudAIError.self) {
            _ = try await service.suggestScanRules(
                from: [makeResult(id: "candidate", safety: .review)],
                proposedRulesURL: liveURL
            )
        }
    }

    @Test("Duplicate resolution suggestions never include protected delete IDs")
    func duplicateResolutionFiltersProtectedDeletes() async throws {
        let defaults = try makeDefaults()
        let configStore = CloudAIConfigurationStore(defaults: defaults)
        configStore.save(CloudAIConfiguration(isEnabled: true, monthlySpendCapCents: 500))
        let transport = FakeCloudAITransport(response: CloudAIResponse(
            text: #"""
            {"suggestions":[{"group_id":"group-1","keep_id":"keep","delete_ids":["review","protected"],"rationale":"keep canonical copy"}]}
            """#,
            inputTokens: 1_000,
            outputTokens: 200
        ))
        let service = CloudAIService(
            configurationStore: configStore,
            keyStore: FakeCloudAPIKeyStore(apiKey: "sk-ant-api03-\(String(repeating: "d", count: 32))"),
            transport: transport,
            usageLedger: CloudAIUsageLedger(defaults: defaults),
            logger: CloudAIRequestLogger(logURL: tempURL("cloud-duplicates-log.jsonl"))
        )
        let group = DuplicateGroup(
            id: "group-1",
            shortHash: "abc123",
            files: [
                makeResult(id: "keep", safety: .safe),
                makeResult(id: "review", safety: .review),
                makeResult(id: "protected", safety: .protected_),
            ],
            perFileSize: 512
        )

        let suggestions = try await service.resolveDuplicates(groups: [group])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].deleteIDs == ["review"])
        #expect(suggestions[0].keepID == "keep")
    }

    @Test("Service reports disabled and missing-key states before network calls")
    func disabledAndMissingKeyStates() async throws {
        let defaults = try makeDefaults()
        let configStore = CloudAIConfigurationStore(defaults: defaults)
        configStore.save(CloudAIConfiguration(isEnabled: false))
        let transport = FakeCloudAITransport(response: CloudAIResponse(text: "{}", inputTokens: 1, outputTokens: 1))
        let service = CloudAIService(
            configurationStore: configStore,
            keyStore: FakeCloudAPIKeyStore(apiKey: nil),
            transport: transport,
            usageLedger: CloudAIUsageLedger(defaults: defaults),
            logger: CloudAIRequestLogger(logURL: tempURL("cloud-disabled-log.jsonl"))
        )

        await #expect(throws: CloudAIError.self) {
            _ = try await service.deepAnalyze(results: [makeResult(id: "one", safety: .safe)])
        }
        #expect(await transport.callCount == 0)

        configStore.save(CloudAIConfiguration(isEnabled: true))
        await #expect(throws: CloudAIError.self) {
            _ = try await service.deepAnalyze(results: [makeResult(id: "one", safety: .safe)])
        }
        #expect(await transport.callCount == 0)
    }

    private func makeResult(
        id: String,
        safety: SafetyLevel,
        size: Int64 = 512,
        tags: [String] = []
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Item \(id)",
            path: "/Users/test/Library/Caches/\(id)",
            size: size,
            safety: safety,
            confidence: 91,
            explanation: "Generated test item.",
            source: SourceAttribution(name: "Example", bundleID: "com.example.app"),
            lastAccessed: Date(timeIntervalSince1970: 1_700_000_000),
            category: "test_cache",
            tags: tags,
            regenerates: true,
            regenerateCommand: "example --rebuild"
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "gargantua-cloud-ai-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-cloud-ai-\(UUID().uuidString)-\(name)")
    }
}

private final class FakeCloudAPIKeyStore: CloudAPIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var apiKey: String?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func save(_ apiKey: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.apiKey = apiKey
    }

    func read() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return apiKey
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        apiKey = nil
    }

    func hasKey() throws -> Bool {
        try read() != nil
    }
}

private actor FakeCloudAITransport: CloudAITransport {
    private let response: CloudAIResponse
    private(set) var callCount = 0
    private(set) var lastRequest: CloudAIRequest?

    init(response: CloudAIResponse) {
        self.response = response
    }

    func complete(_ request: CloudAIRequest, apiKey: String) async throws -> CloudAIResponse {
        callCount += 1
        lastRequest = request
        #expect(apiKey.hasPrefix("sk-ant-"))
        return response
    }

    nonisolated func stream(_ request: CloudAIRequest, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
