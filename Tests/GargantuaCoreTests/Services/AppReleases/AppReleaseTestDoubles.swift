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

    func download(
        _: URL,
        to _: URL,
        as _: AppReleaseDownloadAgent,
        maxBytes _: Int64,
        progress _: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Int64 { 0 }
}

/// Writes files into a temporary Homebrew prefix, e.g.
/// `Caskroom/foo/.metadata/INSTALL_RECEIPT.json`. Callers remove the root.
enum CaskroomFixture {
    static func makePrefix(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caskroom-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }
}
