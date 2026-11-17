import Foundation
import Yams

/// Where a catalog entry's releases come from.
public struct AppReleaseCatalogSourceSpec: Sendable, Equatable, Decodable {
    public enum SourceType: String, Sendable, Decodable {
        case sparkle
        case github
    }

    public let type: SourceType
    public let feedURL: URL?
    public let repo: String?
    public let asset: String?
    public let assetX86_64: String?
    public let tagPrefix: String?

    enum CodingKeys: String, CodingKey {
        case type
        case feedURL = "feed_url"
        case repo
        case asset
        case assetX86_64 = "asset_x86_64"
        case tagPrefix = "tag_prefix"
    }
}

/// One curated update source from the bundled `update_catalog` snapshot of
/// `gargantua-rules/rules/updates`.
public struct AppReleaseCatalogEntry: Sendable, Equatable, Decodable {
    public enum InstallPolicy: String, Sendable, Decodable {
        case auto
        case linkOnly = "link_only"
    }

    public let id: String
    public let name: String
    public let bundleID: String
    public let teamID: String
    public let source: AppReleaseCatalogSourceSpec
    public let install: InstallPolicy
    public let homepage: URL?
    public let explanation: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case bundleID = "bundle_id"
        case teamID = "team_id"
        case source
        case install
        case homepage
        case explanation
    }

    /// The asset regex for this Mac's architecture.
    var assetPattern: String? {
        #if arch(x86_64)
            source.assetX86_64 ?? source.asset
        #else
            source.asset
        #endif
    }

    /// Re-checks what the upstream validator enforces, so a bad snapshot
    /// entry is dropped instead of trusted.
    func validationError() -> String? {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            return "\(id): team_id must be a 10-character Team ID"
        }
        if let homepage, !homepage.isHTTPS {
            return "\(id): homepage must be https"
        }
        switch source.type {
        case .sparkle:
            guard source.feedURL?.isHTTPS == true else { return "\(id): feed_url must be https" }
        case .github:
            guard let repo = source.repo,
                  repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
            else { return "\(id): repo must be owner/name" }
            for pattern in [source.asset, source.assetX86_64].compactMap({ $0 }) {
                guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                    return "\(id): invalid asset regex"
                }
            }
            guard source.asset != nil else { return "\(id): github source needs asset" }
        }
        return nil
    }
}

/// The curated update catalog, keyed by bundle ID.
public struct AppReleaseCatalog: Sendable {
    public let entries: [String: AppReleaseCatalogEntry]
    /// Files or entries that failed to parse or validate; they are skipped.
    public let errors: [String]

    public init(entries: [AppReleaseCatalogEntry], errors: [String] = []) {
        var byBundleID: [String: AppReleaseCatalogEntry] = [:]
        for entry in entries where byBundleID[entry.bundleID] == nil {
            byBundleID[entry.bundleID] = entry
        }
        self.entries = byBundleID
        self.errors = errors
    }

    public func entry(for bundleID: String) -> AppReleaseCatalogEntry? {
        entries[bundleID]
    }

    /// The snapshot shipped in the app bundle.
    public static let bundled: AppReleaseCatalog = {
        guard let directory = Bundle.gargantuaCoreResources.url(forResource: "update_catalog", withExtension: nil) else {
            return AppReleaseCatalog(entries: [], errors: ["update_catalog resource missing"])
        }
        return load(from: directory)
    }()

    /// Loads every `*.yaml` / `*.yml` under `directory`. A broken file or
    /// entry is recorded in `errors` and skipped; the rest still load.
    public static func load(from directory: URL) -> AppReleaseCatalog {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [AppReleaseCatalogEntry] = []
        var errors: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else { continue }
            do {
                let parsed = try parse(yaml: String(contentsOf: url, encoding: .utf8))
                entries.append(contentsOf: parsed.entries)
                errors.append(contentsOf: parsed.errors.map { "\(url.lastPathComponent): \($0)" })
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return AppReleaseCatalog(entries: entries.sorted { $0.id < $1.id }, errors: errors)
    }

    static func parse(yaml: String) throws -> (entries: [AppReleaseCatalogEntry], errors: [String]) {
        let file = try YAMLDecoder().decode(CatalogFile.self, from: yaml)
        var entries: [AppReleaseCatalogEntry] = []
        var errors: [String] = []
        for (index, item) in file.updateSources.enumerated() {
            switch item.result {
            case .success(let entry):
                if let problem = entry.validationError() {
                    errors.append(problem)
                } else {
                    entries.append(entry)
                }
            case .failure(let error):
                errors.append("update_sources[\(index)]: \(error)")
            }
        }
        return (entries, errors)
    }
}

/// Release candidates for apps listed in the curated catalog. Every candidate
/// carries the entry's pinned Team ID.
public struct AppReleaseCatalogSource: AppReleaseSourcing {
    public let kind: AppReleaseSourceKind = .catalog

    private let catalog: AppReleaseCatalog
    private let http: any AppReleaseHTTPFetching
    private let sparkle: SparkleAppcastSource

    public init(
        catalog: AppReleaseCatalog = .bundled,
        http: any AppReleaseHTTPFetching,
        sparkle: SparkleAppcastSource
    ) {
        self.catalog = catalog
        self.http = http
        self.sparkle = sparkle
    }

    /// Bundle IDs the catalog covers, so the check service can keep the
    /// plain Sparkle source from fetching the same feed twice.
    public var coveredBundleIDs: Set<String> { Set(catalog.entries.keys) }

    public func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome] {
        let work = apps.compactMap { app in catalog.entry(for: app.bundleID).map { (app.bundleID, $0) } }
        let outcomes = await boundedMap(work) { bundleID, entry in
            (bundleID, await outcome(for: entry))
        }
        return Dictionary(outcomes) { first, _ in first }
    }

    func outcome(for entry: AppReleaseCatalogEntry) async -> AppReleaseSourceOutcome {
        switch entry.source.type {
        case .sparkle:
            guard let feedURL = entry.source.feedURL else { return .failed("Catalog entry has no feed.") }
            return Self.pinned(await sparkle.latestRelease(feedURL: feedURL), to: entry)
        case .github:
            return await gitHubOutcome(for: entry)
        }
    }

    /// Re-labels a feed result as a catalog candidate with the entry's Team
    /// ID pin and install policy. The homepage fallback is https because
    /// `validationError()` dropped any entry whose homepage isn't.
    static func pinned(_ outcome: AppReleaseSourceOutcome, to entry: AppReleaseCatalogEntry) -> AppReleaseSourceOutcome {
        guard case .found(var candidate) = outcome else { return outcome }
        candidate.source = .catalog
        candidate.vendorURL = candidate.vendorURL ?? entry.homepage
        candidate.pinnedTeamID = entry.teamID
        candidate.allowsInPlaceInstall = entry.install == .auto
        candidate.isSparkleFeed = candidate.isSparkleFeed || entry.source.type == .sparkle
        return .found(candidate)
    }

    // MARK: - GitHub Releases

    private func gitHubOutcome(for entry: AppReleaseCatalogEntry) async -> AppReleaseSourceOutcome {
        guard let repo = entry.source.repo,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
        else { return .failed("Catalog entry has no repository.") }
        do {
            let response = try await http.get(url, etag: nil)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: response.data)
            return Self.candidate(from: release, entry: entry)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func candidate(from release: GitHubRelease, entry: AppReleaseCatalogEntry) -> AppReleaseSourceOutcome {
        guard release.draft != true, release.prerelease != true else { return .noEligibleRelease }

        var tag = release.tagName
        if let prefix = entry.source.tagPrefix, !prefix.isEmpty, tag.hasPrefix(prefix) {
            tag.removeFirst(prefix.count)
        }
        let version = AppReleaseVersion(short: tag, build: nil)
        guard version.short != nil, !version.isPrerelease else { return .noEligibleRelease }

        // Exactly one matching asset, or no download at all: picking the
        // first of several matches could install the wrong build.
        let matches: [GitHubReleaseAsset] = {
            guard let pattern = entry.assetPattern,
                  let regex = try? NSRegularExpression(pattern: pattern)
            else { return [] }
            return release.assets.filter { asset in
                let range = NSRange(asset.name.startIndex..., in: asset.name)
                return regex.firstMatch(in: asset.name, range: range) != nil
            }
        }()
        let asset = matches.count == 1 ? matches.first : nil
        let downloadURL = asset?.browserDownloadURL.httpsOnly
        let sha256 = asset?.digest.flatMap { digest -> String? in
            guard digest.hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst("sha256:".count))
        }

        return .found(AppReleaseCandidate(
            source: .catalog,
            version: version,
            downloadURL: downloadURL,
            expectedLength: asset?.size,
            sha256: sha256,
            releaseNotesURL: release.htmlURL,
            vendorURL: release.htmlURL?.httpsOnly ?? entry.homepage,
            pinnedTeamID: entry.teamID,
            allowsInPlaceInstall: entry.install == .auto,
            isSparkleFeed: false
        ))
    }
}

private struct CatalogFile: Decodable {
    let updateSources: [LossyCatalogEntry]

    enum CodingKeys: String, CodingKey {
        case updateSources = "update_sources"
    }
}

/// Decodes one entry without failing the whole file.
private struct LossyCatalogEntry: Decodable {
    let result: Result<AppReleaseCatalogEntry, Error>

    init(from decoder: Decoder) throws {
        result = Result { try AppReleaseCatalogEntry(from: decoder) }
    }
}

/// The fields of GitHub's `releases/latest` response the catalog uses.
struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64?
    /// `sha256:<hex>` on assets uploaded since GitHub started recording digests.
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }
}
