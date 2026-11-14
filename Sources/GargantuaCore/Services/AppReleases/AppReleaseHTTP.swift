import Darwin
import Foundation
import os

/// Response of a conditional GET. A `304` comes back with `statusCode == 304`
/// and empty data, not as an error.
public struct AppReleaseHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data
    public let etag: String?

    public init(statusCode: Int, data: Data, etag: String? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.etag = etag
    }

    public var isNotModified: Bool { statusCode == 304 }
}

public enum AppReleaseHTTPError: Error, Equatable, LocalizedError {
    /// The URL, or a redirect hop, is not https.
    case insecureURL(String)
    case status(Int)
    case tooLarge(limit: Int64)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url): "Refused a non-HTTPS address: \(url)"
        case .status(let code): "The server answered HTTP \(code)."
        case .tooLarge(let limit): "The download is larger than \(limit / 1_048_576) MB."
        case .network(let message): message
        }
    }
}

/// Network seam for the App Updater. Every request is https-only, including
/// each redirect hop.
public protocol AppReleaseHTTPFetching: Sendable {
    func get(_ url: URL, etag: String?) async throws -> AppReleaseHTTPResponse

    /// Downloads `url` to `destination` (which must not exist) and returns the
    /// byte count. Throws `.tooLarge` once the body passes `maxBytes`.
    /// `progress` gets the bytes received and the expected total (nil when the
    /// server didn't declare one), throttled, off the main actor, with a last
    /// call at completion.
    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Int64
}

extension AppReleaseHTTPFetching {
    func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws -> Int64 {
        try await download(url, to: destination, maxBytes: maxBytes) { _, _ in }
    }
}

/// Decides when a streaming download reports: after the body has grown by 1%
/// of the expected length or 256 KiB, whichever is smaller (256 KiB when the
/// length is unknown).
struct DownloadProgressThrottle {
    static let maxStep: Int64 = 256 * 1024
    private let step: Int64
    private var lastReported: Int64 = 0

    init(expected: Int64?) {
        step = expected.map { min(max($0 / 100, 1), Self.maxStep) } ?? Self.maxStep
    }

    mutating func shouldReport(received: Int64) -> Bool {
        guard received - lastReported >= step else { return false }
        lastReported = received
        return true
    }
}

public struct DefaultAppReleaseHTTPClient: AppReleaseHTTPFetching {
    public static let userAgent = "Gargantua-AppUpdater"
    /// Largest `get` body accepted. Homebrew's cask.json, the biggest
    /// response the updater reads, is about 20 MB.
    public static let maxResponseBytes: Int64 = 64 * 1_048_576

    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maxResponseBytes: Int64

    public init(
        session: URLSession = Self.makeSession(),
        requestTimeout: TimeInterval = 20,
        maxResponseBytes: Int64 = Self.maxResponseBytes
    ) {
        self.session = session
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
    }

    /// Ephemeral: no cookies, no URL cache shared with the rest of the app.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }

    public func get(_ url: URL, etag: String?) async throws -> AppReleaseHTTPResponse {
        var request = try Self.request(url, timeout: requestTimeout)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (response, _) = try await BoundedTransfer(request: request, limit: maxResponseBytes, file: nil).run(on: session)
        if response.isNotModified {
            return AppReleaseHTTPResponse(statusCode: response.statusCode, data: Data(), etag: etag)
        }
        return response
    }

    public func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Int64 {
        let request = try Self.request(url, timeout: 60)
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AppReleaseHTTPError.network("Couldn't create the download file: \(String(cString: strerror(errno)))")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let (_, byteCount) = try await BoundedTransfer(request: request, limit: maxBytes, file: file, progress: progress).run(on: session)
            try file.close()
            return byteCount
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func request(_ url: URL, timeout: TimeInterval) throws(AppReleaseHTTPError) -> URLRequest {
        guard url.isHTTPS else { throw .insecureURL(url.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Status and ETag of a response head, after the https and status rules.
    /// A 304 passes only for a conditional request.
    fileprivate static func head(
        of response: URLResponse,
        for request: URLRequest
    ) throws(AppReleaseHTTPError) -> AppReleaseHTTPResponse {
        let requested = request.url?.absoluteString ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw .network("Not an HTTP response for \(requested)")
        }
        let head = AppReleaseHTTPResponse(
            statusCode: http.statusCode,
            data: Data(),
            etag: http.value(forHTTPHeaderField: "ETag")
        )
        let notModified = request.value(forHTTPHeaderField: "If-None-Match") != nil && head.isNotModified
        // A refused redirect surfaces as its 3xx response; report it as the
        // insecure hop it was.
        if (300 ... 399).contains(http.statusCode), !notModified {
            throw .insecureURL(http.value(forHTTPHeaderField: "Location") ?? requested)
        }
        // The task delegate already refuses every non-https hop, but `session`
        // is injectable, and a background session follows redirects without
        // asking the task delegate.
        if let final = http.url, !final.isHTTPS {
            throw .insecureURL(final.absoluteString)
        }
        guard notModified || (200 ... 299).contains(http.statusCode) else { throw .status(http.statusCode) }
        return head
    }
}

/// One request whose body streams into a file, or into memory when `file` is
/// nil. Refuses a redirect off https, refuses a declared length over `limit`
/// before any body arrives, and cancels the transfer as soon as the body
/// passes `limit`.
private final class BoundedTransfer: NSObject, URLSessionDataDelegate {
    private typealias Outcome = Result<(AppReleaseHTTPResponse, Int64), any Error>

    private struct State {
        var continuation: CheckedContinuation<(AppReleaseHTTPResponse, Int64), any Error>?
        /// Set when the task finished before `run` installed its continuation,
        /// which a cancellation that lands first can cause.
        var outcome: Outcome?
        var head: AppReleaseHTTPResponse?
        var body = Data()
        var received: Int64 = 0
        var failure: AppReleaseHTTPError?
        var expected: Int64?
        var throttle = DownloadProgressThrottle(expected: nil)
    }

    private let request: URLRequest
    private let limit: Int64
    private let file: FileHandle?
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        request: URLRequest,
        limit: Int64,
        file: FileHandle?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) {
        self.request = request
        self.limit = limit
        self.file = file
        self.progress = progress
    }

    /// The response (with the body when it went to memory) and the body's
    /// byte count.
    func run(on session: URLSession) async throws -> (AppReleaseHTTPResponse, Int64) {
        let task = session.dataTask(with: request)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let finished = state.withLock { state -> Outcome? in
                    if state.outcome == nil { state.continuation = continuation }
                    return state.outcome
                }
                if let finished {
                    continuation.resume(with: finished)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.isHTTPS == true ? request : nil
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        do throws(AppReleaseHTTPError) {
            let head = try DefaultAppReleaseHTTPClient.head(of: response, for: request)
            if response.expectedContentLength > limit { throw .tooLarge(limit: limit) }
            let expected: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            state.withLock {
                $0.head = head
                $0.expected = expected
                $0.throttle = DownloadProgressThrottle(expected: expected)
            }
            return .allow
        } catch {
            state.withLock { $0.failure = error }
            return .cancel
        }
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (failed, report) = state.withLock { state -> (Bool, (Int64, Int64?)?) in
            guard state.failure == nil else { return (true, nil) }
            state.received += Int64(data.count)
            guard state.received <= limit else {
                state.failure = .tooLarge(limit: limit)
                return (true, nil)
            }
            let report = state.throttle.shouldReport(received: state.received) ? (state.received, state.expected) : nil
            guard let file else {
                state.body.append(data)
                return (false, report)
            }
            do {
                try file.write(contentsOf: data)
                return (false, report)
            } catch {
                state.failure = .network("Couldn't write the download: \(error.localizedDescription)")
                return (true, nil)
            }
        }
        if failed {
            dataTask.cancel()
        } else if let report {
            progress(report.0, report.1)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock { state in
            let result: Outcome
            if let failure = state.failure {
                result = .failure(failure)
            } else if let error {
                result = .failure(AppReleaseHTTPError.network(error.localizedDescription))
            } else if let head = state.head {
                let response = AppReleaseHTTPResponse(statusCode: head.statusCode, data: state.body, etag: head.etag)
                result = .success((response, state.received))
            } else {
                result = .failure(AppReleaseHTTPError.network("The server sent no response."))
            }
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil { state.outcome = result }
            return (continuation, result)
        }
        if case .success((_, let received)) = result {
            progress(received, state.withLock { $0.expected })
        }
        continuation?.resume(with: result)
    }
}
