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
                .download(URL(string: "https://example.com/big.zip")!, to: file, as: .updater, maxBytes: 1000) { _, _ in }
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
                .download(URL(string: "https://example.com/big.zip")!, to: file, as: .updater, maxBytes: 1000) { _, _ in }
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
            .download(URL(string: "https://example.com/big.zip")!, to: file, as: .updater, maxBytes: 10000) { received, expected in
                reports.withLock { $0.append(received) }
                _ = expecteds.withLock { $0.insert(expected) }
            }

        let received = reports.withLock { $0 }
        let declared = expecteds.withLock { $0 }
        #expect(count == 2000)
        #expect(received.last == 2000)
        #expect(received == received.sorted())
        #expect(declared == [2000])
    }

    @Test("httpsUpgraded keeps https, upgrades default-port http, and refuses the rest")
    func httpsUpgradedRules() {
        func upgraded(_ string: String) -> String? { URL(string: string)?.httpsUpgraded?.absoluteString }
        #expect(upgraded("https://h.example/p") == "https://h.example/p")
        #expect(upgraded("http://h.example/p?q=1") == "https://h.example/p?q=1")
        #expect(upgraded("http://h.example:80/p") == "https://h.example/p")
        #expect(upgraded("http://h.example:8080/p") == nil)
        #expect(upgraded("ftp://h.example/p") == nil)
        #expect(upgraded("http://user:pw@h.example/p") == nil)
        #expect(upgraded("HTTP://h.example/p") == "https://h.example/p")
        #expect(upgraded("http://h.example:443/p") == nil)
    }

    @Test("a redirect to http on the default port is followed over https, never over http")
    func httpRedirectIsUpgraded() async throws {
        let (session, key) = RedirectURLProtocol.makeSession(redirectingTo: "http://mirror.example.net/app.dmg")
        defer { RedirectURLProtocol.remove(key) }
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file) }

        let count = try await DefaultAppReleaseHTTPClient(session: session)
            .download(URL(string: "https://get.example.org/app.dmg")!, to: file, as: .updater, maxBytes: 1000) { _, _ in }

        let seen = RedirectURLProtocol.seen(key)
        #expect(count == RedirectURLProtocol.body.count)
        #expect(seen.contains("https://mirror.example.net/app.dmg"))
        #expect(!seen.contains { $0.hasPrefix("http:") })
    }

    @Test("a download goes out as the agent it was given, on every hop of a redirect")
    func downloadUsesAgent() async throws {
        let (session, key) = RedirectURLProtocol.makeSession(redirectingTo: "https://mirror.example.net/app.dmg")
        defer { RedirectURLProtocol.remove(key) }
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await DefaultAppReleaseHTTPClient(session: session)
            .download(URL(string: "https://get.example.org/app.dmg")!, to: file, as: .homebrew, maxBytes: 1000) { _, _ in }

        let homebrew = "Homebrew (compatible; Gargantua-AppUpdater)"
        #expect(RedirectURLProtocol.agents(key) == [homebrew, homebrew])
        #expect(AppReleaseDownloadAgent.updater.userAgent == "Gargantua-AppUpdater")
        #expect(AppReleaseDownloadAgent.browser.userAgent.hasPrefix("Mozilla/5.0 (Macintosh;"))
        #expect(AppReleaseDownloadAgent.curl.userAgent.hasPrefix("curl/"))
    }

    @Test("a redirect to http on another port is still refused")
    func httpRedirectOnOtherPortIsRefused() async throws {
        let (session, key) = RedirectURLProtocol.makeSession(redirectingTo: "http://mirror.example.net:8080/app.dmg")
        defer { RedirectURLProtocol.remove(key) }
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect {
            try await DefaultAppReleaseHTTPClient(session: session)
                .download(URL(string: "https://get.example.org/app.dmg")!, to: file, as: .updater, maxBytes: 1000) { _, _ in }
        } throws: { error in
            guard case .insecureURL = error as? AppReleaseHTTPError else { return false }
            return true
        }
        #expect(!RedirectURLProtocol.seen(key).contains { $0.hasPrefix("http:") })
    }
}

final class FakeThrottleClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    var now: @Sendable () -> ContinuousClock.Instant { { [current] in current.withLock { $0 } } }
    func advance(_ duration: Duration) { current.withLock { $0 += duration } }
}

@Suite("DownloadProgressThrottle")
struct DownloadProgressThrottleTests {
    private func reports(expected: Int64?, total: Int64, chunk: Int64) -> Int {
        let clock = FakeThrottleClock()
        var throttle = DownloadProgressThrottle(expected: expected, now: clock.now)
        var count = 0
        var received: Int64 = 0
        while received < total {
            received += chunk
            clock.advance(.milliseconds(200))
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
        let clock = FakeThrottleClock()
        var throttle = DownloadProgressThrottle(expected: 10_000_000_000, now: clock.now)
        let early = throttle.shouldReport(received: 256 * 1024 - 1)
        let atStep = throttle.shouldReport(received: 256 * 1024)
        #expect(!early)
        #expect(atStep)
    }

    @Test("byte-eligible reports closer than 100 ms apart are dropped")
    func timeFloor() {
        let clock = FakeThrottleClock()
        var throttle = DownloadProgressThrottle(expected: nil, now: clock.now)
        let step = DownloadProgressThrottle.maxStep
        let first = throttle.shouldReport(received: step)
        clock.advance(.milliseconds(50))
        let tooSoon = throttle.shouldReport(received: step * 2)
        clock.advance(.milliseconds(100))
        let later = throttle.shouldReport(received: step * 2)
        #expect(first)
        #expect(!tooSoon)
        #expect(later)
    }

    @Test("the final report is skipped only when it repeats the last one")
    func finalNotDuplicated() {
        let clock = FakeThrottleClock()
        var throttle = DownloadProgressThrottle(expected: nil, now: clock.now)
        let step = DownloadProgressThrottle.maxStep
        let first = throttle.shouldReport(received: step)
        #expect(first)
        let repeated = throttle.shouldReportFinal(received: step)
        let advanced = throttle.shouldReportFinal(received: step + 5)
        let again = throttle.shouldReportFinal(received: step + 5)
        #expect(!repeated)
        #expect(advanced)
        #expect(!again)
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

/// Answers `get.example.org` with a 302 to the session's target and any other
/// host with a small 200 body, recording every URL it is asked to load.
final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(repeating: 0x41, count: 64)

    private struct Record {
        let target: String
        var seen: [String] = []
        /// The User-Agent of each request, in the order of `seen`.
        var agents: [String?] = []
    }

    private static let keyHeader = "X-Redirect-Key"
    private static let state = OSAllocatedUnfairLock<[String: Record]>(initialState: [:])

    static func makeSession(redirectingTo target: String) -> (URLSession, String) {
        let key = UUID().uuidString
        state.withLock { $0[key] = Record(target: target) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectURLProtocol.self]
        configuration.httpAdditionalHeaders = [keyHeader: key]
        return (URLSession(configuration: configuration), key)
    }

    static func seen(_ key: String) -> [String] { state.withLock { $0[key]?.seen ?? [] } }

    static func agents(_ key: String) -> [String?] { state.withLock { $0[key]?.agents ?? [] } }

    static func remove(_ key: String) { _ = state.withLock { $0.removeValue(forKey: key) } }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
        guard let url = request.url else { return client?.urlProtocol(self, didFailWithError: URLError(.badURL)) ?? () }
        let target = Self.state.withLock { state -> String? in
            state[key]?.seen.append(url.absoluteString)
            state[key]?.agents.append(request.value(forHTTPHeaderField: "User-Agent"))
            return state[key]?.target
        }
        if url.host == "get.example.org", let target, let targetURL = URL(string: target),
           let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]) {
            var next = request
            next.url = targetURL
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // A refused redirect delivers the 3xx itself; a followed one cancels this load.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}
