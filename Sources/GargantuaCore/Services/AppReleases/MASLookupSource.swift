import Foundation

/// Mac App Store versions from the public iTunes lookup API. Link-only: the
/// App Store installs the update.
public struct MASLookupSource: AppReleaseSourcing {
    public let kind = AppReleaseSourceKind.appStore

    private let http: any AppReleaseHTTPFetching
    private let countryCode: String
    private let batchSize: Int

    public init(
        http: any AppReleaseHTTPFetching,
        countryCode: String = Locale.current.region?.identifier.lowercased() ?? "us",
        batchSize: Int = 50
    ) {
        self.http = http
        self.countryCode = countryCode
        self.batchSize = max(1, batchSize)
    }

    private struct LookupResult: Decodable {
        let bundleId: String?
        let version: String?
        let trackViewUrl: String?
        let minimumOsVersion: String?
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    public func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome] {
        var seen = Set<String>()
        let ids = apps.filter(\.isMAS).map(\.bundleID).filter { seen.insert($0).inserted }
        let batches = stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0..<min($0 + batchSize, ids.count)]) }
        var outcomes: [String: AppReleaseSourceOutcome] = [:]
        await withTaskGroup(of: [String: AppReleaseSourceOutcome].self) { group in
            for batch in batches {
                group.addTask { await lookUp(batch: batch) }
            }
            for await partial in group { outcomes.merge(partial) { first, _ in first } }
        }
        return outcomes
    }

    private func lookUp(batch: [String]) async -> [String: AppReleaseSourceOutcome] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: batch.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: countryCode),
        ]
        guard let url = components?.url else {
            return Dictionary(uniqueKeysWithValues: batch.map { ($0, .failed("Invalid lookup URL")) })
        }
        do {
            let response = try await http.get(url, etag: nil)
            let decoded = try JSONDecoder().decode(LookupResponse.self, from: response.data)
            var outcomes: [String: AppReleaseSourceOutcome] = [:]
            for result in decoded.results {
                guard let bundleID = result.bundleId, batch.contains(bundleID), outcomes[bundleID] == nil,
                      let version = result.version, !version.isEmpty else { continue }
                outcomes[bundleID] = .found(AppReleaseCandidate(
                    source: kind,
                    version: AppReleaseVersion(short: version, build: nil),
                    minimumSystemVersion: result.minimumOsVersion,
                    payloadKind: .unknown,
                    vendorURL: result.trackViewUrl.flatMap(URL.init(string:))
                ))
            }
            return outcomes
        } catch {
            let message = error.localizedDescription
            return Dictionary(uniqueKeysWithValues: batch.map { ($0, .failed(message)) })
        }
    }
}
