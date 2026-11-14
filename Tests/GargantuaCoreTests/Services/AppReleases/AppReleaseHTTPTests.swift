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
        // 2000 chunks at 5 ms is ten seconds of body: finishing it would take
        // a cancel delayed far past any loaded CI machine's scheduling jitter.
        let script = ChunkedURLProtocol.Script(headers: [:], chunkSize: 400, chunkCount: 2000)
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

    @Test("download reports growing byte counts against the declared length, ending on the full body")
    func downloadReportsProgress() async throws {
        let script = ChunkedURLProtocol.Script(headers: ["Content-Length": "2000"], chunkSize: 400, chunkCount: 5)
        let (session, key) = ChunkedURLProtocol.makeSession(script)
        defer { ChunkedURLProtocol.remove(key) }
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file) }
        let reports = OSAllocatedUnfairLock<[Int64]>(initialState: [])
        let expecteds = OSAllocatedUnfairLock<Set<Int64?>>(initialState: [])

        let count = try await DefaultAppReleaseHTTPClient(session: session)
            .download(URL(string: "https://example.com/big.zip")!, to: file, maxBytes: 10000) { received, expected in
                reports.withLock { $0.append(received) }
                expecteds.withLock { $0.insert(expected) }
            }

        let received = reports.withLock { $0 }
        let declared = expecteds.withLock { $0 }
        #expect(count == 2000)
        #expect(received.last == 2000)
        #expect(received == received.sorted())
        #expect(declared == [2000])
    }
}

@Suite("DownloadProgressThrottle")
struct DownloadProgressThrottleTests {
    private func reports(expected: Int64?, total: Int64, chunk: Int64) -> Int {
        var throttle = DownloadProgressThrottle(expected: expected)
        var count = 0
        var received: Int64 = 0
        while received < total {
            received += chunk
            if throttle.shouldReport(received: received) { count += 1 }
        }
        return count
    }

    @Test("a known length reports at about 1% steps, not per chunk")
    func knownLength() {
        // 10 MB in 1 KB chunks: 1% is about 100 KB, so about 100 reports.
        let count = reports(expected: 10_000_000, total: 10_000_000, chunk: 1000)
        #expect((95 ... 101).contains(count))
    }

    @Test("an unknown length reports every 256 KiB")
    func unknownLength() {
        let count = reports(expected: nil, total: 2 * 1024 * 1024, chunk: 1024)
        #expect(count == 8)
    }

    @Test("a huge body is capped at 256 KiB steps")
    func hugeLengthCap() {
        var throttle = DownloadProgressThrottle(expected: 10_000_000_000)
        let early = throttle.shouldReport(received: 256 * 1024 - 1)
        let atStep = throttle.shouldReport(received: 256 * 1024)
        #expect(!early)
        #expect(atStep)
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
