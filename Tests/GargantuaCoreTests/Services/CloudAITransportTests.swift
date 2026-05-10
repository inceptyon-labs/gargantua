import Foundation
import Testing
@testable import GargantuaCore

@Suite("AnthropicMessagesTransport")
struct CloudAITransportTests {

    // MARK: - Helpers

    private func makeRequest() -> CloudAIRequest {
        CloudAIRequest(
            feature: .deepAnalysis,
            model: "claude-3-5-haiku-20241022",
            maxTokens: 100,
            systemPrompt: "You are helpful.",
            userPrompt: "Hello"
        )
    }

    /// Creates a transport backed by a session that serves every request with
    /// the supplied handler. Handlers are keyed by UUID and stored in the
    /// session's additional HTTP headers so parallel tests don't clobber each
    /// other's state.
    private func makeTransport(
        handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) -> (transport: AnthropicMessagesTransport, teardown: () -> Void) {
        let (session, key) = MockURLProtocol.makeSession(handler: handler)
        let transport = AnthropicMessagesTransport(session: session)
        return (transport, { MockURLProtocol.removeHandler(for: key) })
    }

    private func makeTransport(statusCode: Int, body: String, headers: [String: String] = [:])
        -> (transport: AnthropicMessagesTransport, teardown: () -> Void) {
        makeTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
    }

    // MARK: - complete()

    @Test("complete returns response on 200 with valid JSON")
    func completeSuccess() async throws {
        let body = """
        {
          "id": "msg_abc",
          "content": [{"type": "text", "text": "Hello back"}],
          "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let (transport, teardown) = makeTransport(statusCode: 200, body: body, headers: ["request-id": "req_123"])
        defer { teardown() }

        let response = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")

        #expect(response.text == "Hello back")
        #expect(response.inputTokens == 10)
        #expect(response.outputTokens == 5)
        #expect(response.requestID == "req_123")
    }

    @Test("complete falls back to response id when request-id header is absent")
    func completeFallsBackToResponseID() async throws {
        let body = """
        {
          "id": "msg_fallback",
          "content": [{"type": "text", "text": "Hi"}],
          "usage": {"input_tokens": 1, "output_tokens": 1}
        }
        """
        let (transport, teardown) = makeTransport(statusCode: 200, body: body)
        defer { teardown() }

        let response = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
        #expect(response.requestID == "msg_fallback")
    }

    @Test("complete sums multiple text content blocks")
    func completeMultipleContentBlocks() async throws {
        let body = """
        {
          "id": "msg_multi",
          "content": [
            {"type": "text", "text": "Line one"},
            {"type": "text", "text": "Line two"}
          ],
          "usage": {"input_tokens": 5, "output_tokens": 5}
        }
        """
        let (transport, teardown) = makeTransport(statusCode: 200, body: body)
        defer { teardown() }

        let response = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
        #expect(response.text == "Line one\nLine two")
    }

    @Test("complete throws emptyResponse when all content blocks have no text")
    func completeThrowsOnEmptyText() async throws {
        let body = """
        {
          "id": "msg_empty",
          "content": [{"type": "tool_use", "text": null}],
          "usage": {"input_tokens": 1, "output_tokens": 1}
        }
        """
        let (transport, teardown) = makeTransport(statusCode: 200, body: body)
        defer { teardown() }

        await #expect(throws: CloudAIError.emptyResponse) {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
        }
    }

    @Test("complete throws transport error on 4xx with error envelope")
    func completeThrowsOn4xx() async throws {
        let (transport, teardown) = makeTransport(
            statusCode: 401,
            body: #"{"error": {"message": "Invalid API key"}}"#
        )
        defer { teardown() }

        do {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-ant-bad")
            Issue.record("Expected transport error")
        } catch CloudAIError.transport(let status, let message) {
            #expect(status == 401)
            #expect(message.contains("Invalid API key"))
        }
    }

    @Test("complete throws transport error on 5xx with raw body fallback")
    func completeThrowsOn5xxRawBody() async throws {
        let (transport, teardown) = makeTransport(statusCode: 500, body: "Internal Server Error")
        defer { teardown() }

        do {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
            Issue.record("Expected transport error")
        } catch CloudAIError.transport(let status, _) {
            #expect(status == 500)
        }
    }

    @Test("complete sets correct HTTP headers in request")
    func completeSetsHeaders() async throws {
        let captured = UncheckedSendableBox<URLRequest?>(nil)

        let (transport, teardown) = makeTransport { request in
            captured.value = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [:]
            )!
            let body = Data("""
            {"id":"x","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}
            """.utf8)
            return (body, response)
        }
        defer { teardown() }

        _ = try? await transport.complete(makeRequest(), apiKey: "sk-ant-mykey")

        #expect(captured.value?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-mykey")
        #expect(captured.value?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(captured.value?.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    // MARK: - Retry logic

    @Test("complete does not retry on cancellation — exits after one attempt")
    func noRetryOnCancellation() async throws {
        let counter = Counter()

        let (transport, teardown) = makeTransport { _ in
            counter.increment()
            throw CancellationError()
        }
        defer { teardown() }

        do {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
        } catch {}

        #expect(counter.value == 1)
    }

    @Test("complete retries on 429 up to maxRetries times")
    func retriesOn429() async throws {
        let counter = Counter()

        let (_, key) = MockURLProtocol.makeSession { request in
            counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"error":{"message":"rate limited"}}"#.utf8), response)
        }
        defer { MockURLProtocol.removeHandler(for: key) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Mock-Handler-Key": key]
        let session = URLSession(configuration: config)
        let transport = AnthropicMessagesTransport(maxRetries: 2, session: session)

        do {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
        } catch CloudAIError.transport(let status, _) {
            #expect(status == 429)
        }
        // 1 initial + 2 retries = 3 total
        #expect(counter.value == 3)
    }

    @Test("complete does not retry on 400 bad request — exits after one attempt")
    func noRetryOn400() async throws {
        let counter = Counter()

        let (transport, teardown) = makeTransport { request in
            counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"error":{"message":"bad request"}}"#.utf8), response)
        }
        defer { teardown() }

        do {
            _ = try await transport.complete(makeRequest(), apiKey: "sk-ant-test")
        } catch CloudAIError.transport(let status, _) {
            #expect(status == 400)
        }
        #expect(counter.value == 1)
    }

    // MARK: - stream()

    @Test("stream yields text deltas and finishes")
    func streamYieldsTextDeltas() async throws {
        let sseLines = [
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}"#,
            "data: [DONE]",
        ].joined(separator: "\n") + "\n"

        let (transport, teardown) = makeTransport(statusCode: 200, body: sseLines)
        defer { teardown() }

        var chunks: [String] = []
        for try await chunk in transport.stream(makeRequest(), apiKey: "sk-ant-test") {
            chunks.append(chunk)
        }
        #expect(chunks == ["Hello", " world"])
    }

    @Test("stream ignores non-text-delta events")
    func streamIgnoresNonTextDelta() async throws {
        let sseLines = [
            #"data: {"type":"message_start","message":{"id":"msg_x"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Only this"}}"#,
            #"data: {"type":"message_stop"}"#,
            "data: [DONE]",
        ].joined(separator: "\n") + "\n"

        let (transport, teardown) = makeTransport(statusCode: 200, body: sseLines)
        defer { teardown() }

        var chunks: [String] = []
        for try await chunk in transport.stream(makeRequest(), apiKey: "sk-ant-test") {
            chunks.append(chunk)
        }
        #expect(chunks == ["Only this"])
    }

    @Test("stream skips lines that don't start with 'data: '")
    func streamSkipsNonDataLines() async throws {
        let sseLines = [
            ": keep-alive",
            "event: ping",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Signal"}}"#,
            "data: [DONE]",
        ].joined(separator: "\n") + "\n"

        let (transport, teardown) = makeTransport(statusCode: 200, body: sseLines)
        defer { teardown() }

        var chunks: [String] = []
        for try await chunk in transport.stream(makeRequest(), apiKey: "sk-ant-test") {
            chunks.append(chunk)
        }
        #expect(chunks == ["Signal"])
    }

    @Test("stream throws transport error on non-200 status")
    func streamThrowsOnErrorStatus() async throws {
        let (transport, teardown) = makeTransport(statusCode: 403, body: "Forbidden")
        defer { teardown() }

        do {
            for try await _ in transport.stream(makeRequest(), apiKey: "sk-ant-test") {}
            Issue.record("Expected transport error")
        } catch CloudAIError.transport(let status, _) {
            #expect(status == 403)
        }
    }
}

// MARK: - MockURLProtocol

/// Thread-safe URLProtocol stub. Each mock session gets a unique UUID key
/// embedded in its additional headers; `startLoading` extracts that key to
/// look up and invoke the per-test handler, so parallel tests never share state.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func makeSession(handler: @escaping Handler) -> (URLSession, String) {
        let key = UUID().uuidString
        lock.withLock { handlers[key] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Mock-Handler-Key": key]
        return (URLSession(configuration: config), key)
    }

    static func removeHandler(for key: String) {
        lock.withLock { handlers.removeValue(forKey: key) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Mock-Handler-Key") ?? ""
        let handler = MockURLProtocol.lock.withLock { MockURLProtocol.handlers[key] }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test utilities

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class UncheckedSendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
