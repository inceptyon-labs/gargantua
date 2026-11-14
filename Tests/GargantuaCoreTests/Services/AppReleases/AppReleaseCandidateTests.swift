import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseCandidate")
struct AppReleaseCandidateTests {
    private func candidate(link: String) -> AppReleaseCandidate {
        AppReleaseCandidate(
            source: .sparkle,
            version: AppReleaseVersion(short: "2.0", build: nil),
            releaseNotesURL: URL(string: link),
            vendorURL: URL(string: link)
        )
    }

    @Test("feed-supplied vendor and release-notes links keep only https")
    func linksAreHTTPSOnly() {
        for link in ["ssh://example.com/x", "file:///etc/passwd", "http://example.com/notes"] {
            #expect(candidate(link: link).vendorURL == nil, "\(link)")
            #expect(candidate(link: link).releaseNotesURL == nil, "\(link)")
        }
        let https = candidate(link: "HTTPS://example.com/notes")
        #expect(https.vendorURL?.absoluteString == "HTTPS://example.com/notes")
        #expect(https.releaseNotesURL?.absoluteString == "HTTPS://example.com/notes")
    }
}
