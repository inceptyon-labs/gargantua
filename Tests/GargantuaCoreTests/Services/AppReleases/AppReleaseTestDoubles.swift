import Foundation
import os
@testable import GargantuaCore

/// Scripted `AppReleaseHTTPFetching`: records requests, answers from a closure.
final class StubAppReleaseHTTP: AppReleaseHTTPFetching {
    typealias Handler = @Sendable (URL, String?) throws -> AppReleaseHTTPResponse

    private struct State {
        var requests: [(url: URL, etag: String?)] = []
        var handler: Handler
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ handler: @escaping Handler) {
        state = OSAllocatedUnfairLock(uncheckedState: State(handler: handler))
    }

    var requests: [(url: URL, etag: String?)] { state.withLock { $0.requests } }

    func setHandler(_ new: @escaping Handler) { state.withLock { $0.handler = new } }

    func get(_ url: URL, etag: String?) async throws -> AppReleaseHTTPResponse {
        let handler = state.withLock { state -> Handler in
            state.requests.append((url, etag))
            return state.handler
        }
        return try handler(url, etag)
    }

    func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws -> Int64 { 0 }
}
