import Foundation

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
    /// byte count. Throws `.tooLarge` past `maxBytes`.
    func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws -> Int64
}

public struct DefaultAppReleaseHTTPClient: AppReleaseHTTPFetching {
    public static let userAgent = "Gargantua-AppUpdater"

    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(session: URLSession = Self.makeSession(), requestTimeout: TimeInterval = 20) {
        self.session = session
        self.requestTimeout = requestTimeout
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
        try Self.requireHTTPS(url)
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: HTTPSOnlyRedirects())
        } catch {
            throw AppReleaseHTTPError.network(error.localizedDescription)
        }
        let http = try Self.httpResponse(response, requested: url)
        if http.statusCode == 304 {
            return AppReleaseHTTPResponse(statusCode: 304, data: Data(), etag: etag)
        }
        guard (200...299).contains(http.statusCode) else { throw AppReleaseHTTPError.status(http.statusCode) }
        return AppReleaseHTTPResponse(
            statusCode: http.statusCode,
            data: data,
            etag: http.value(forHTTPHeaderField: "ETag")
        )
    }

    public func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws -> Int64 {
        try Self.requireHTTPS(url)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await session.download(for: request, delegate: HTTPSOnlyRedirects())
        } catch {
            throw AppReleaseHTTPError.network(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let http = try Self.httpResponse(response, requested: url)
        guard (200...299).contains(http.statusCode) else { throw AppReleaseHTTPError.status(http.statusCode) }

        let size = (try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard size <= maxBytes else { throw AppReleaseHTTPError.tooLarge(limit: maxBytes) }

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return size
    }

    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw AppReleaseHTTPError.insecureURL(url.absoluteString)
        }
    }

    /// A refused redirect surfaces as its 3xx response; report it as the
    /// insecure hop it was.
    private static func httpResponse(_ response: URLResponse, requested url: URL) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw AppReleaseHTTPError.network("Not an HTTP response for \(url.absoluteString)")
        }
        if (300...399).contains(http.statusCode), http.statusCode != 304 {
            let location = http.value(forHTTPHeaderField: "Location") ?? url.absoluteString
            throw AppReleaseHTTPError.insecureURL(location)
        }
        if let final = http.url {
            try requireHTTPS(final)
        }
        return http
    }
}

/// Follows a redirect only when the next hop is https.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
