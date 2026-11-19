import Foundation

/// Mac App Store versions from the public iTunes lookup API. Link-only: the
/// App Store installs the update.
///
/// An app sold for iPhone, iPad and Mac as one purchase comes back as its
/// iOS listing (`kind` `software`), whose version and minimum OS are the iOS
/// ones: TestFlight read 4.4.1 there while the Mac App Store had 4.4.0. Its
/// Mac version is read from its Mac App Store page instead.
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
        let kind: String?
        let trackId: Int?

        var isMacListing: Bool { kind == "mac-software" }
    }

    static let unreadableMacVersion =
        "The App Store lists this app's iPhone and iPad version, and its Mac version couldn't be read."
    /// Mac App Store pages fetched at once, for apps with an iOS listing.
    private static let pageConcurrency = 4

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    public func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome] {
        var seen = Set<String>()
        let ids = apps.filter(\.isMAS).map(\.bundleID).filter { seen.insert($0).inserted }
        let batches = stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0 ..< min($0 + batchSize, ids.count)]) }
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
            var iOSListings: [(bundleID: String, result: LookupResult)] = []
            for result in decoded.results {
                guard let bundleID = result.bundleId, batch.contains(bundleID), outcomes[bundleID] == nil,
                      !iOSListings.contains(where: { $0.bundleID == bundleID }),
                      let version = result.version, !version.isEmpty else { continue }
                if result.isMacListing {
                    outcomes[bundleID] = .found(candidate(version: version, minimumSystemVersion: result.minimumOsVersion, result))
                } else {
                    iOSListings.append((bundleID, result))
                }
            }
            for chunk in stride(from: 0, to: iOSListings.count, by: Self.pageConcurrency) {
                let listings = iOSListings[chunk ..< min(chunk + Self.pageConcurrency, iOSListings.count)]
                await withTaskGroup(of: (String, AppReleaseSourceOutcome).self) { group in
                    for listing in listings {
                        group.addTask { (listing.bundleID, await macListingOutcome(listing.result)) }
                    }
                    for await (bundleID, outcome) in group { outcomes[bundleID] = outcome }
                }
            }
            return outcomes
        } catch {
            let message = error.localizedDescription
            return Dictionary(uniqueKeysWithValues: batch.map { ($0, .failed(message)) })
        }
    }

    /// The release on the app's Mac App Store page. Its minimum macOS isn't
    /// read, so none is set: the listing's minimum is the iOS one.
    private func macListingOutcome(_ result: LookupResult) async -> AppReleaseSourceOutcome {
        guard let trackID = result.trackId,
              let url = URL(string: "https://apps.apple.com/\(countryCode)/app/id\(trackID)?platform=mac"),
              let response = try? await http.get(url, etag: nil),
              let version = MASStorePage.macVersion(fromHTML: response.data)
        else { return .failed(Self.unreadableMacVersion) }
        return .found(candidate(version: version, minimumSystemVersion: nil, result))
    }

    private func candidate(version: String, minimumSystemVersion: String?, _ result: LookupResult) -> AppReleaseCandidate {
        AppReleaseCandidate(
            source: kind,
            version: AppReleaseVersion(short: version, build: nil),
            minimumSystemVersion: minimumSystemVersion,
            payloadKind: .unknown,
            vendorURL: result.trackViewUrl.flatMap(URL.init(string:))
        )
    }
}

/// Reads an App Store web page's embedded data (`serialized-server-data`).
enum MASStorePage {
    /// The newest version in the page's version history, which on a page
    /// opened with `platform=mac` is the Mac one. Nil when the page doesn't
    /// have that shape or the value doesn't start with a digit.
    static func macVersion(fromHTML data: Data) -> String? {
        guard let html = String(bytes: data, encoding: .utf8),
              let open = html.range(of: #"<script type="application/json" id="serialized-server-data">"#),
              let close = html.range(of: "</script>", range: open.upperBound ..< html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound ..< close.lowerBound].utf8))
        else { return nil }

        let latest = (((root as? [String: Any])?["data"] as? [Any])?.first as? [String: Any])?["data"] as? [String: Any]
        let shelf = (latest?["shelfMapping"] as? [String: Any])?["mostRecentVersion"] as? [String: Any]
        let history = ((shelf?["seeAllAction"] as? [String: Any])?["pageData"] as? [String: Any])?["shelves"] as? [Any]
        let entry = ((history?.first as? [String: Any])?["items"] as? [Any])?.first as? [String: Any]
        guard let version = (entry?["primarySubtitle"] as? String)?.trimmingCharacters(in: .whitespaces),
              version.first?.isNumber == true
        else { return nil }
        return version
    }
}
