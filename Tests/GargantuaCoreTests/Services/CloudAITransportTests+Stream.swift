import Foundation
import Testing
@testable import GargantuaCore

extension CloudAITransportTests {
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
