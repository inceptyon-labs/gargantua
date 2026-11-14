import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppcastParser and Sparkle selection")
struct AppcastParserTests {
    private static let ns = "xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\""
    private let host = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    private func feed(_ items: String) -> Data {
        Data("<?xml version=\"1.0\"?><rss version=\"2.0\" \(Self.ns)><channel>\(items)</channel></rss>".utf8)
    }

    private func best(_ xml: String, base: URL? = nil) throws -> AppReleaseSourceOutcome {
        SparkleAppcastSource.bestCandidate(
            from: try AppcastParser.parse(feed(xml)), osVersion: host, baseURL: base
        )
    }

    private func candidate(_ outcome: AppReleaseSourceOutcome) -> AppReleaseCandidate? {
        if case .found(let value) = outcome { return value }
        return nil
    }

    @Test func parsesAttributeFormEnclosure() throws {
        let items = try AppcastParser.parse(feed("""
        <item><title>2.0</title><enclosure url="https://x.test/a.zip" length="1234" type="application/zip"
        sparkle:version="200" sparkle:shortVersionString="2.0" sparkle:edSignature="SIG"/></item>
        """))
        #expect(items.count == 1)
        #expect(items[0].version == "200")
        #expect(items[0].shortVersion == "2.0")
        #expect(items[0].enclosureLength == 1234)
        #expect(items[0].edSignature == "SIG")
    }

    @Test func parsesChildElementForm() throws {
        let items = try AppcastParser.parse(feed("""
        <item><sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
        <enclosure url="https://x.test/a.dmg" length="1" type="application/x-apple-diskimage"/></item>
        """))
        #expect(items[0].version == "300")
        #expect(items[0].shortVersion == "3.0")
        #expect(items[0].minimumSystemVersion == "12.0")
    }

    @Test func channelItemIsExcluded() throws {
        let outcome = try best("""
        <item><sparkle:channel>beta</sparkle:channel><sparkle:shortVersionString>9.0</sparkle:shortVersionString>
        <enclosure url="https://x.test/b.zip"/></item>
        <item><sparkle:shortVersionString>1.0</sparkle:shortVersionString><enclosure url="https://x.test/a.zip"/></item>
        """)
        #expect(candidate(outcome)?.version.short == "1.0")
    }

    @Test func minimumSystemVersionAboveHostIsExcluded() throws {
        let outcome = try best("""
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><enclosure url="https://x.test/b.zip"/></item>
        """)
        #expect(outcome == .noEligibleRelease)
    }

    @Test func picksNewestWhenFeedListsOldestFirst() throws {
        let outcome = try best("""
        <item><sparkle:shortVersionString>1.0</sparkle:shortVersionString><enclosure url="https://x.test/1.zip"/></item>
        <item><sparkle:shortVersionString>1.10</sparkle:shortVersionString><enclosure url="https://x.test/10.zip"/></item>
        <item><sparkle:shortVersionString>1.2</sparkle:shortVersionString><enclosure url="https://x.test/2.zip"/></item>
        """)
        #expect(candidate(outcome)?.downloadURL?.lastPathComponent == "10.zip")
    }

    @Test func informationalUpdateHasNoDownload() throws {
        let outcome = try best("""
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString><sparkle:informationalUpdate/>
        <link>https://x.test/news</link><enclosure url="https://x.test/b.zip"/></item>
        """)
        #expect(candidate(outcome)?.downloadURL == nil)
        #expect(candidate(outcome)?.vendorURL?.absoluteString == "https://x.test/news")
    }

    @Test func httpEnclosureHasNoDownload() throws {
        let outcome = try best("""
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString><enclosure url="http://x.test/b.zip"/></item>
        """)
        #expect(candidate(outcome)?.downloadURL == nil)
    }

    @Test func relativeEnclosureResolvesAgainstFeedURL() throws {
        let outcome = try best("""
        <item><sparkle:shortVersionString>1.5</sparkle:shortVersionString>
        <sparkle:fullReleaseNotesLink>notes.html</sparkle:fullReleaseNotesLink>
        <enclosure url="App-1.5.zip"/></item>
        """, base: URL(string: "https://pkgs.test/stable/appcast.xml"))
        #expect(candidate(outcome)?.downloadURL?.absoluteString == "https://pkgs.test/stable/App-1.5.zip")
        #expect(candidate(outcome)?.releaseNotesURL?.absoluteString == "https://pkgs.test/stable/notes.html")
    }

    @Test func malformedXMLThrows() {
        #expect(throws: (any Error).self) { try AppcastParser.parse(Data("<rss><channel><item></channel>".utf8)) }
    }
}
