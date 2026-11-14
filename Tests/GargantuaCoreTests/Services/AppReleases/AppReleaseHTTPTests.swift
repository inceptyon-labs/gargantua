import Foundation
import os
import Testing
@testable import GargantuaCore

@Suite("AppReleaseHTTP")
struct AppReleaseHTTPTests {
    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
    }

    @Test("a declared length over the limit is refused before the body is read")
    func declaredLengthOverLimit() async throws {
        // The body itself fits; only the declared length is over.
        let script = ChunkedURLProtocol.Script(headers: ["Content-Length": "4000"], chunkSize: 400, chunkCount: 2)
        let (session, key) = ChunkedURLProtocol.makeSession(script)
        defer { ChunkedURLProtocol.remove(key) }
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: AppReleaseHTTPError.tooLarge(limit: 1000)) {
            try await DefaultAppReleaseHTTPClient(session: session)
                .download(URL(string: "https://example.com/big.zip")!, to: file, maxBytes: 1000)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a body that passes the limit stops the transfer instead of finishing it")
    func streamingStopsAtLimit() async throws {
        let script = ChunkedURLProtocol.Script(headers: [:], chunkSize: 400, chunkCount: 50)
        let (session, key) = ChunkedURLProtocol.makeSession(script)
        defer { ChunkedURLProtocol.remove(key) }
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: AppReleaseHTTPError.tooLarge(limit: 1000)) {
            try await DefaultAppReleaseHTTPClient(session: session)
                .download(URL(string: "https://example.com/big.zip")!, to: file, maxBytes: 1000)
        }
        #expect(ChunkedURLProtocol.sentChunks(key) < script.chunkCount)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a get body over the response cap is refused")
    func getIsCapped() async throws {
        let script = ChunkedURLProtocol.Script(headers: [:], chunkSize: 400, chunkCount: 5)
        let (session, key) = ChunkedURLProtocol.makeSession(script)
        defer { ChunkedURLProtocol.remove(key) }

        await #expect(throws: AppReleaseHTTPError.tooLarge(limit: 1000)) {
            try await DefaultAppReleaseHTTPClient(session: session, maxResponseBytes: 1000)
                .get(URL(string: "https://example.com/feed.xml")!, etag: nil)
        }
    }
}

/// Answers every request with a 200 and then `chunkCount` chunks, one every
/// few milliseconds on the loading thread's run loop, counting how many went
/// out before the client stopped the load.
final class ChunkedURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        let headers: [String: String]
        let chunkSize: Int
        let chunkCount: Int
    }

    private static let keyHeader = "X-Chunked-Key"
    private static let state = OSAllocatedUnfairLock<[String: (script: Script, sent: Int)]>(initialState: [:])

    static func makeSession(_ script: Script) -> (URLSession, String) {
        let key = UUID().uuidString
        state.withLock { $0[key] = (script, 0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        configuration.httpAdditionalHeaders = [keyHeader: key]
        return (URLSession(configuration: configuration), key)
    }

    static func sentChunks(_ key: String) -> Int { state.withLock { $0[key]?.sent ?? 0 } }

    static func remove(_ key: String) { _ = state.withLock { $0.removeValue(forKey: key) } }

    /// Touched only on the loading thread.
    private var timer: Timer?

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
        guard let script = Self.state.withLock({ $0[key]?.script }), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: script.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 0x41, count: script.chunkSize)
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let sent = Self.state.withLock { state -> Int? in
                guard let entry = state[key], entry.sent < entry.script.chunkCount else { return nil }
                state[key]?.sent += 1
                return entry.sent + 1
            }
            guard sent != nil else {
                timer.invalidate()
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didLoad: chunk)
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    override func stopLoading() {
        timer?.invalidate()
    }
}
