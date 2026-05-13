import Foundation
import Testing
@testable import GargantuaCore

@Suite("AnthropicMessagesTransport")
struct CloudAITransportTests {

    // MARK: - Helpers

    func makeRequest() -> CloudAIRequest {
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
    func makeTransport(
        handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) -> (transport: AnthropicMessagesTransport, teardown: () -> Void) {
        let (session, key) = MockURLProtocol.makeSession(handler: handler)
        let transport = AnthropicMessagesTransport(session: session)
        return (transport, { MockURLProtocol.removeHandler(for: key) })
    }

    func makeTransport(statusCode: Int, body: String, headers: [String: String] = [:])
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
}

// MARK: - MockURLProtocol

/// Thread-safe URLProtocol stub. Each mock session gets a unique UUID key
/// embedded in its additional headers; `startLoading` extracts that key to
/// look up and invoke the per-test handler, so parallel tests never share state.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

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

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

final class UncheckedSendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
