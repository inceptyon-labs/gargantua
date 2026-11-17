import Foundation

/// Release lookups from each app's own Sparkle appcast (`SUFeedURL`).
public struct SparkleAppcastSource: AppReleaseSourcing {
    public let kind = AppReleaseSourceKind.sparkle

    private let http: any AppReleaseHTTPFetching
    private let osVersion: OperatingSystemVersion

    public init(
        http: any AppReleaseHTTPFetching,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.http = http
        self.osVersion = osVersion
    }

    public func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome] {
        let targets = apps.compactMap { app in app.sparkleFeedURL.map { (app.bundleID, $0) } }
        let outcomes = await boundedMap(targets) { bundleID, feed in
            (bundleID, await latestRelease(feedURL: feed))
        }
        return Dictionary(outcomes) { first, _ in first }
    }

    public func latestRelease(feedURL: URL) async -> AppReleaseSourceOutcome {
        do {
            let response = try await http.get(feedURL, etag: nil)
            let items = try AppcastParser.parse(response.data)
            return Self.bestCandidate(from: items, osVersion: osVersion, baseURL: feedURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Newest stable item this OS can run. Feeds are not reliably ordered.
    static func bestCandidate(
        from items: [AppcastItem],
        osVersion: OperatingSystemVersion,
        baseURL: URL? = nil
    ) -> AppReleaseSourceOutcome {
        func resolve(_ raw: String?) -> URL? {
            guard let raw, !raw.isEmpty else { return nil }
            return URL(string: raw, relativeTo: baseURL)?.absoluteURL
        }
        let eligible = items.compactMap { item -> (AppcastItem, AppReleaseVersion)? in
            guard item.channel == nil else { return nil }
            let version = AppReleaseVersion(short: item.shortVersion, build: item.version)
            guard version.short != nil || version.build != nil, !version.isPrerelease else { return nil }
            // An unparsable bound doesn't exclude the item; install
            // verification checks the bundle's own LSMinimumSystemVersion.
            if let minimum = item.minimumSystemVersion, osVersion.meets(minimum: minimum) == false { return nil }
            if let maximum = item.maximumSystemVersion, osVersion.meets(maximum: maximum) == false { return nil }
            return (item, version)
        }
        guard var best = eligible.first else { return .noEligibleRelease }
        for candidate in eligible.dropFirst() where candidate.1.compare(to: best.1) == .orderedDescending {
            best = candidate
        }
        let (item, version) = best

        let enclosure = resolve(item.enclosureURL)
        let downloadURL = item.isInformationalUpdate ? nil : enclosure?.httpsOnly
        return .found(AppReleaseCandidate(
            source: .sparkle,
            version: version,
            downloadURL: downloadURL,
            expectedLength: item.enclosureLength,
            edSignature: item.edSignature,
            minimumSystemVersion: item.minimumSystemVersion,
            payloadKind: .infer(url: enclosure, mimeType: item.enclosureType),
            releaseNotesURL: resolve(item.releaseNotesURL),
            vendorURL: resolve(item.link)
        ))
    }
}
