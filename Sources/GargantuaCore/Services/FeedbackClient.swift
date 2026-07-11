import Foundation

/// Bug report or feature request submitted from Settings → About.
public struct FeedbackReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case bug
        case feature
    }

    public struct Diagnostics: Codable, Equatable, Sendable {
        public var appVersion: String
        public var osVersion: String
        public var build: String

        public init(appVersion: String, osVersion: String, build: String) {
            self.appVersion = appVersion
            self.osVersion = osVersion
            self.build = build
        }
    }

    public var kind: Kind
    public var title: String
    public var details: String
    public var email: String?
    public var diagnostics: Diagnostics

    public init(kind: Kind, title: String, details: String, email: String?, diagnostics: Diagnostics) {
        self.kind = kind
        self.title = title
        self.details = details
        self.email = email
        self.diagnostics = diagnostics
    }
}

public enum FeedbackClientError: Error, Equatable {
    case rateLimited
    case server(status: Int)
    case network(String)
}

/// Posts feedback to the intake worker, which files it as an issue in the
/// private feedback repo. The worker holds the GitHub token; nothing secret
/// ships in the app.
public struct FeedbackClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://gargantua-feedback.jnew008538.workers.dev/report")!

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = FeedbackClient.defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    public func submit(_ report: FeedbackReport) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(report)

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw FeedbackClientError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackClientError.network("Not an HTTP response")
        }
        switch http.statusCode {
        case 200 ... 299:
            return
        case 429:
            throw FeedbackClientError.rateLimited
        default:
            throw FeedbackClientError.server(status: http.statusCode)
        }
    }
}
