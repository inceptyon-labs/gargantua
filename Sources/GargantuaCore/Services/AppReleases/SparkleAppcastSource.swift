import Foundation

/// Release lookups from each app's own Sparkle appcast (`SUFeedURL`).
public struct SparkleAppcastSource: AppReleaseSourcing {
    public let kind = AppReleaseSourceKind.sparkle

    private let http: any AppReleaseHTTPFetching
    private let osVersion: OperatingSystemVersion
    private let maxConcurrent: Int

    public init(
        http: any AppReleaseHTTPFetching,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        maxConcurrent: Int = 8
    ) {
        self.http = http
        self.osVersion = osVersion
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome] {
        let targets = apps.compactMap { app in app.sparkleFeedURL.map { (app.bundleID, $0) } }
        var results: [String: AppReleaseSourceOutcome] = [:]
        await withTaskGroup(of: (String, AppReleaseSourceOutcome).self) { group in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let (bundleID, feed) = targets[next]
                next += 1
                group.addTask { (bundleID, await latestRelease(feedURL: feed)) }
            }
            for _ in 0..<maxConcurrent { enqueue() }
            while let (bundleID, outcome) = await group.next() {
                results[bundleID] = outcome
                enqueue()
            }
        }
        return results
    }

    public func latestRelease(feedURL: URL) async -> AppReleaseSourceOutcome {
        do {
            let response = try await http.get(feedURL, etag: nil)
            let items = try AppcastParser.parse(response.data)
            return Self.bestCandidate(from: items, osVersion: osVersion, source: kind, baseURL: feedURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Newest stable item this OS can run. Feeds are not reliably ordered.
    static func bestCandidate(
        from items: [AppcastItem],
        osVersion: OperatingSystemVersion,
        source: AppReleaseSourceKind,
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
            if let minimum = item.minimumSystemVersion, osVersion.isOlder(than: minimum) { return nil }
            if let maximum = item.maximumSystemVersion, osVersion.isNewer(than: maximum) { return nil }
            return (item, version)
        }
        guard var best = eligible.first else { return .noEligibleRelease }
        for candidate in eligible.dropFirst() where candidate.1.compare(to: best.1) == .orderedDescending {
            best = candidate
        }
        let (item, version) = best

        let enclosure = resolve(item.enclosureURL)
        let secure = enclosure?.scheme?.lowercased() == "https" ? enclosure : nil
        let downloadURL = item.isInformationalUpdate ? nil : secure
        return .found(AppReleaseCandidate(
            source: source,
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

private extension OperatingSystemVersion {
    var components: [Int] { [majorVersion, minorVersion, patchVersion] }

    static func parse(_ string: String) -> [Int] {
        let parts = string.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        return parts + Array(repeating: 0, count: 3 - parts.count)
    }

    func isOlder(than string: String) -> Bool { components.lexicographicallyPrecedes(Self.parse(string)) }
    func isNewer(than string: String) -> Bool { Self.parse(string).lexicographicallyPrecedes(components) }
}
