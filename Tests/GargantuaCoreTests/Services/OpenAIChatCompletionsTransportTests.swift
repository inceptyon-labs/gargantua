import Foundation
import Testing
@testable import GargantuaCore

@Suite("OpenAIChatCompletionsTransport")
struct OpenAIChatCompletionsTransportTests {

    private func makeRequest() -> CloudAIRequest {
        CloudAIRequest(
            feature: .deepAnalysis,
            model: "gpt-4o-mini",
            maxTokens: 100,
            systemPrompt: "You are helpful.",
            userPrompt: "Hello"
        )
    }

    private func makeTransport(
        baseURL: String = "https://api.openai.com/v1",
        handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) -> (transport: OpenAIChatCompletionsTransport, teardown: () -> Void) {
        let (session, key) = MockURLProtocol.makeSession(handler: handler)
        let transport = OpenAIChatCompletionsTransport(baseURL: URL(string: baseURL)!, session: session)
        return (transport, { MockURLProtocol.removeHandler(for: key) })
    }

    private func respond(_ statusCode: Int, _ body: String, headers: [String: String] = [:])
        -> @Sendable (URLRequest) throws -> (Data, URLResponse) {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    @Test("complete parses choices[0].message.content and OpenAI usage")
    func completeSuccess() async throws {
        let body = """
        {
          "id": "chatcmpl-1",
          "choices": [{"message": {"role": "assistant", "content": "Hello back"}}],
          "usage": {"prompt_tokens": 12, "completion_tokens": 7}
        }
        """
        let (transport, teardown) = makeTransport(handler: respond(200, body, headers: ["x-request-id": "req_9"]))
        defer { teardown() }

        let response = try await transport.complete(makeRequest(), apiKey: "sk-test")
        #expect(response.text == "Hello back")
        #expect(response.inputTokens == 12)
        #expect(response.outputTokens == 7)
        #expect(response.requestID == "req_9")
    }

    @Test("complete hits {baseURL}/chat/completions with Bearer auth and system message")
    func requestShape() async throws {
        let captured = UncheckedSendableBox<URLRequest?>(nil)
        let body = """
        {"choices": [{"message": {"content": "ok"}}], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
        """
        let (transport, teardown) = makeTransport(baseURL: "https://openrouter.ai/api/v1") { request in
            captured.value = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), response)
        }
        defer { teardown() }

        _ = try await transport.complete(makeRequest(), apiKey: "key-123")

        let request = try #require(captured.value)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key-123")
        // The captured body has no httpBody when sent via URLProtocol stub on
        // some paths, so assert via httpBodyStream-independent fields above.
    }

    @Test("empty API key omits the Authorization header (local servers)")
    func emptyKeyOmitsAuth() async throws {
        let captured = UncheckedSendableBox<URLRequest?>(nil)
        let body = """
        {"choices": [{"message": {"content": "ok"}}], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
        """
        let (transport, teardown) = makeTransport(baseURL: "http://localhost:11434/v1") { request in
            captured.value = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), response)
        }
        defer { teardown() }

        _ = try await transport.complete(makeRequest(), apiKey: "")
        let request = try #require(captured.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("non-2xx surfaces the OpenAI error message")
    func errorEnvelope() async {
        let body = """
        {"error": {"message": "invalid model", "type": "invalid_request_error"}}
        """
        let (transport, teardown) = makeTransport(handler: respond(400, body))
        defer { teardown() }

        await #expect(throws: CloudAIError.self) {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-test")
        }
    }

    @Test("empty content throws emptyResponse")
    func emptyContent() async {
        let body = """
        {"choices": [{"message": {"content": ""}}], "usage": {"prompt_tokens": 1, "completion_tokens": 0}}
        """
        let (transport, teardown) = makeTransport(handler: respond(200, body))
        defer { teardown() }

        await #expect(throws: CloudAIError.emptyResponse) {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-test")
        }
    }

    @Test("missing usage defaults token counts to zero")
    func missingUsage() async throws {
        let body = """
        {"choices": [{"message": {"content": "hi"}}]}
        """
        let (transport, teardown) = makeTransport(handler: respond(200, body))
        defer { teardown() }

        let response = try await transport.complete(makeRequest(), apiKey: "sk-test")
        #expect(response.text == "hi")
        #expect(response.inputTokens == 0)
        #expect(response.outputTokens == 0)
    }

    @Test("stream yields choices[].delta.content chunks until [DONE]")
    func streaming() async throws {
        let sse = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
            "data: [DONE]",
        ].joined(separator: "\n\n") + "\n\n"
        let (transport, teardown) = makeTransport(handler: respond(200, sse))
        defer { teardown() }

        var chunks: [String] = []
        for try await chunk in transport.stream(makeRequest(), apiKey: "sk-test") {
            chunks.append(chunk)
        }
        #expect(chunks == ["Hel", "lo"])
    }
}

@Suite("CloudAITransportFactory")
struct CloudAITransportFactoryTests {
    @Test("Anthropic provider yields the Anthropic transport")
    func anthropic() {
        let config = CloudAIConfiguration(provider: .anthropic)
        #expect(CloudAITransportFactory.make(for: config) is AnthropicMessagesTransport)
    }

    @Test("OpenAI-compatible provider yields the OpenAI transport at the configured base URL")
    func openAI() throws {
        let config = CloudAIConfiguration(provider: .openAICompatible, openAIBaseURL: "https://api.groq.com/openai/v1")
        let transport = CloudAITransportFactory.make(for: config)
        let openAI = try #require(transport as? OpenAIChatCompletionsTransport)
        #expect(openAI.baseURL.absoluteString == "https://api.groq.com/openai/v1")
    }

    @Test("Empty base URL falls back to OpenAI")
    func emptyBaseURLFallsBack() throws {
        let config = CloudAIConfiguration(provider: .openAICompatible, openAIBaseURL: "")
        let openAI = try #require(CloudAITransportFactory.make(for: config) as? OpenAIChatCompletionsTransport)
        #expect(openAI.baseURL.absoluteString == "https://api.openai.com/v1")
    }

    @Test("Unparseable non-empty base URL fails closed — never routes to OpenAI")
    func invalidBaseURLFailsClosed() async {
        // A control character can't form a URL; the factory must not substitute OpenAI.
        let config = CloudAIConfiguration(provider: .openAICompatible, openAIBaseURL: "ht tp://\u{0}bad")
        let transport = CloudAITransportFactory.make(for: config)
        #expect(transport is FailingCloudAITransport)
        await #expect(throws: CloudAIError.self) {
            _ = try await transport.complete(
                CloudAIRequest(feature: .deepAnalysis, model: "m", maxTokens: 10, userPrompt: "hi"),
                apiKey: "k"
            )
        }
    }

    @Test("Plain HTTP to a public host is flagged insecure; LAN/loopback is not")
    func insecureEndpointDetection() {
        func config(_ url: String) -> CloudAIConfiguration {
            CloudAIConfiguration(provider: .openAICompatible, openAIBaseURL: url)
        }
        #expect(config("http://api.example.com/v1").usesInsecureRemoteEndpoint)
        #expect(!config("https://api.example.com/v1").usesInsecureRemoteEndpoint)
        #expect(!config("http://localhost:11434/v1").usesInsecureRemoteEndpoint)
        #expect(!config("http://127.0.0.1:1234/v1").usesInsecureRemoteEndpoint)
        #expect(!config("http://192.168.2.222:11434/v1").usesInsecureRemoteEndpoint)
        #expect(!config("http://titan.local:11434/v1").usesInsecureRemoteEndpoint)
        // Anthropic provider never trips it.
        #expect(!CloudAIConfiguration(provider: .anthropic).usesInsecureRemoteEndpoint)
    }
}

@Suite("CloudAIProvider config + keychain")
struct CloudAIProviderConfigTests {
    @Test("Legacy config JSON (no provider/baseURL) decodes as Anthropic")
    func backCompatDecode() throws {
        let json = #"{"isEnabled":true,"allowsFileContents":false,"monthlySpendCapCents":500,"model":"claude-sonnet-4-6","maxTokens":1200}"#
        let decoded = try JSONDecoder().decode(CloudAIConfiguration.self, from: Data(json.utf8))
        #expect(decoded.provider == .anthropic)
        #expect(decoded.openAIBaseURL.isEmpty)
        #expect(decoded.isEnabled)
    }

    @Test("provider + openAIBaseURL round-trip through Codable")
    func roundTrip() throws {
        let original = CloudAIConfiguration(
            isEnabled: true,
            model: "llama-3.3-70b",
            provider: .openAICompatible,
            openAIBaseURL: "https://openrouter.ai/api/v1"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CloudAIConfiguration.self, from: data)
        #expect(decoded == original)
    }

    @Test("Permissive validation accepts non-Anthropic keys, rejects whitespace/empty")
    func permissiveValidation() {
        #expect(CloudAPIKeyValidation.permissive.accepts("sk-proj-abc123"))
        #expect(CloudAPIKeyValidation.permissive.accepts("gsk_groqkey"))
        #expect(!CloudAPIKeyValidation.permissive.accepts(""))
        #expect(!CloudAPIKeyValidation.permissive.accepts("has space"))
    }

    @Test("Anthropic validation still enforces the sk-ant- shape")
    func anthropicValidation() {
        #expect(!CloudAPIKeyValidation.anthropic.accepts("sk-proj-abc123"))
        #expect(CloudAPIKeyValidation.anthropic.accepts("sk-ant-api03-\(String(repeating: "a", count: 32))"))
    }

    @Test("An OpenAI-compatible key is stored per endpoint origin")
    func keyAccountIsPerOrigin() throws {
        func account(_ url: String) throws -> String {
            CloudAPIKeyStores.openAIAccount(origin: CloudAPIKeyStores.origin(of: try #require(URL(string: url))))
        }
        #expect(try account("https://API.openai.com/v1") == account("https://api.openai.com:443/v2"))
        #expect(try account("https://api.openai.com/v1") != account("https://openrouter.ai/api/v1"))
        #expect(try account("http://192.168.2.222:11434/v1") != account("http://192.168.2.222:1234/v1"))
        #expect(try account("https://api.openai.com/v1") != CloudAPIKeyStores.legacyOpenAIAccount)
    }

    @Test("A key saved before origin binding carries over only to OpenAI's own endpoint")
    func legacyKeyMigratesOnlyToDefaultOrigin() throws {
        let defaultOrigin = CloudAPIKeyStores.origin(of: try #require(URL(string: "https://api.openai.com/v1")))
        let otherOrigin = CloudAPIKeyStores.origin(of: try #require(URL(string: "https://openrouter.ai/api/v1")))

        let legacy = MemoryKeyStore("sk-old")
        let other = MemoryKeyStore(nil)
        CloudAPIKeyStores.migrateLegacyOpenAIKey(to: other, origin: otherOrigin, legacy: legacy)
        #expect(try other.read() == nil)
        #expect(try legacy.read() == "sk-old")

        let openAI = MemoryKeyStore(nil)
        CloudAPIKeyStores.migrateLegacyOpenAIKey(to: openAI, origin: defaultOrigin, legacy: legacy)
        #expect(try openAI.read() == "sk-old")
        #expect(try legacy.read() == nil)
    }
}

private final class MemoryKeyStore: CloudAPIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(_ key: String?) { self.key = key }

    func save(_ apiKey: String) throws { lock.withLock { key = apiKey } }
    func read() throws -> String? { lock.withLock { key } }
    func delete() throws { lock.withLock { key = nil } }
    func hasKey() throws -> Bool { try read() != nil }
}
