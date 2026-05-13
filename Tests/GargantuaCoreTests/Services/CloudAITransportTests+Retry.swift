import Foundation
import Testing
@testable import GargantuaCore

extension CloudAITransportTests {
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
}
