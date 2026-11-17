import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseCatalog")
struct AppReleaseCatalogTests {
    private static let validYAML = """
    update_sources:
      - id: example_github
        name: Example
        bundle_id: com.example.Example
        team_id: ABCDE12345
        source:
          type: github
          repo: example/example-mac
          asset: '^Example-[0-9.]+\\.dmg$'
          tag_prefix: v
        install: auto
        homepage: https://example.com
        explanation: Released on GitHub.
      - id: bad_http
        name: Bad
        bundle_id: com.example.Bad
        team_id: ABCDE12345
        source:
          type: sparkle
          feed_url: http://example.com/appcast.xml
        install: auto
        explanation: Plain http feed.
      - id: bad_team
        name: Bad Team
        bundle_id: com.example.BadTeam
        team_id: nope
        source:
          type: sparkle
          feed_url: https://example.com/appcast.xml
        install: auto
        explanation: Malformed team.
    """

    @Test("valid entries load; http feeds and malformed Team IDs are dropped with an error")
    func parseAndValidate() throws {
        let parsed = try AppReleaseCatalog.parse(yaml: Self.validYAML)
        #expect(parsed.entries.map(\.bundleID) == ["com.example.Example"])
        #expect(parsed.errors.count == 2)
        #expect(parsed.entries.first?.source.tagPrefix == "v")
    }

    @Test("the bundled snapshot loads cleanly and every entry pins a Team ID")
    func bundledSnapshot() {
        let catalog = AppReleaseCatalog.bundled
        #expect(catalog.errors.isEmpty)
        #expect(!catalog.entries.isEmpty)
        #expect(catalog.entries.values.allSatisfy { $0.teamID.count == 10 })
        #expect(catalog.successorTeam(bundleID: "org.audacityteam.audacity", installedTeam: "AWEYX923UX") == "6EPAF2X3PR")
    }

    @Test("team successions load beside the sources; a malformed one is dropped with an error")
    func parseSuccessions() throws {
        let parsed = try AppReleaseCatalog.parse(yaml: """
        team_successions:
          - bundle_id: com.example.Example
            name: Example
            from_team_id: ABCDE12345
            to_team_id: FGHIJ67890
            explanation: Sold.
          - bundle_id: com.example.Same
            name: Same
            from_team_id: ABCDE12345
            to_team_id: ABCDE12345
            explanation: Not a change.
          - bundle_id: com.example.Short
            name: Short
            from_team_id: nope
            to_team_id: FGHIJ67890
            explanation: Malformed team.
        """)
        #expect(parsed.entries.isEmpty)
        #expect(parsed.successions.map(\.bundleID) == ["com.example.Example"])
        #expect(parsed.errors.count == 2)

        let catalog = AppReleaseCatalog(entries: [], successions: parsed.successions)
        #expect(catalog.successorTeam(bundleID: "com.example.Example", installedTeam: "ABCDE12345") == "FGHIJ67890")
        #expect(catalog.successorTeam(bundleID: "com.example.Example", installedTeam: "FGHIJ67890") == nil)
        #expect(catalog.successorTeam(bundleID: "com.example.Other", installedTeam: "ABCDE12345") == nil)
    }

    private func release(tag: String, assets: [(String, String?)], prerelease: Bool = false) throws -> GitHubRelease {
        let json: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/example/example-mac/releases/tag/\(tag)",
            "prerelease": prerelease,
            "draft": false,
            "assets": assets.map { name, digest in
                var asset: [String: Any] = [
                    "name": name,
                    "browser_download_url": "https://github.com/example/example-mac/releases/download/\(tag)/\(name)",
                    "size": 1234,
                ]
                if let digest { asset["digest"] = digest }
                return asset
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    @Test("GitHub release maps to a pinned candidate with the asset digest as sha256")
    func gitHubCandidate() throws {
        let entry = try #require(try AppReleaseCatalog.parse(yaml: Self.validYAML).entries.first)
        let outcome = AppReleaseCatalogSource.candidate(
            from: try release(tag: "v1.4.0", assets: [("Example-1.4.0.dmg", "sha256:abc123"), ("Example-1.4.0.zip", nil)]),
            entry: entry
        )
        guard case .found(let candidate) = outcome else {
            Issue.record("expected a candidate, got \(outcome)")
            return
        }
        #expect(candidate.version.short == "1.4.0")
        #expect(candidate.sha256 == "abc123")
        #expect(candidate.expectedLength == 1234)
        #expect(candidate.pinnedTeamID == "ABCDE12345")
        #expect(candidate.payloadKind == .dmg)
        #expect(candidate.source == .catalog)
        #expect(!candidate.isSparkleFeed)
    }

    @Test("ambiguous or missing asset match yields no download; prereleases yield nothing")
    func gitHubFailClosed() throws {
        let entry = try #require(try AppReleaseCatalog.parse(yaml: Self.validYAML).entries.first)
        let twoMatches = AppReleaseCatalogSource.candidate(
            from: try release(tag: "v2.0", assets: [("Example-2.0.dmg", nil), ("Example-2.0.1.dmg", nil)]),
            entry: entry
        )
        if case .found(let candidate) = twoMatches {
            #expect(candidate.downloadURL == nil)
        } else {
            Issue.record("expected a link-only candidate")
        }
        let prerelease = try release(tag: "v3.0", assets: [], prerelease: true)
        #expect(AppReleaseCatalogSource.candidate(from: prerelease, entry: entry) == .noEligibleRelease)
    }

    @Test("a catalog Sparkle feed result keeps the signature requirement and gains the pin")
    func pinnedSparkle() throws {
        let yaml = """
        update_sources:
          - id: feed
            name: Feed
            bundle_id: com.example.Feed
            team_id: ABCDE12345
            source: {type: sparkle, feed_url: 'https://example.com/appcast.xml'}
            install: link_only
            explanation: Feed set in code.
        """
        let entry = try #require(try AppReleaseCatalog.parse(yaml: yaml).entries.first)
        let feedCandidate = AppReleaseCandidate(
            source: .sparkle,
            version: AppReleaseVersion(short: "5.0", build: "500"),
            downloadURL: URL(string: "https://example.com/Feed.zip"),
            edSignature: "sig"
        )
        guard case .found(let pinned) = AppReleaseCatalogSource.pinned(.found(feedCandidate), to: entry) else {
            Issue.record("expected a candidate")
            return
        }
        #expect(pinned.source == .catalog)
        #expect(pinned.isSparkleFeed)
        #expect(pinned.pinnedTeamID == "ABCDE12345")
        #expect(!pinned.allowsInPlaceInstall)
        #expect(pinned.edSignature == "sig")
    }
}
