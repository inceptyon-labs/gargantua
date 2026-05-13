import Foundation
import Testing
@testable import GargantuaCore

extension CloudAITransportTests {
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
}
