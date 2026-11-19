import Foundation
import Testing
@testable import GargantuaCore

@Suite("MASLookupSource")
struct MASLookupSourceTests {
    @Test func batchesRequestsAndDecodesResults() async {
        let http = StubAppReleaseHTTP { url, _ in
            let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "bundleId" }?.value?.split(separator: ",") ?? []
            let results = ids.filter { $0 != "com.test.missing" }.map {
                "{\"bundleId\":\"\($0)\",\"kind\":\"mac-software\",\"version\":\"2.0\",\"trackViewUrl\":\"https://apps.apple.com/app/\($0)\",\"minimumOsVersion\":\"13.0\"}"
            }
            return AppReleaseHTTPResponse(statusCode: 200, data: Data("{\"results\":[\(results.joined(separator: ","))]}".utf8))
        }
        var apps = (0 ..< 5).map { InstalledApp(bundleID: "com.test.a\($0)", name: "A\($0)", url: URL(fileURLWithPath: "/A\($0).app"), isMAS: true) }
        apps.append(InstalledApp(bundleID: "com.test.missing", name: "M", url: URL(fileURLWithPath: "/M.app"), isMAS: true))
        apps.append(InstalledApp(bundleID: "com.test.notmas", name: "N", url: URL(fileURLWithPath: "/N.app")))

        let outcomes = await MASLookupSource(http: http, countryCode: "us", batchSize: 2).lookUp(apps)

        #expect(http.requests.count == 3)
        #expect(outcomes.count == 5)
        #expect(outcomes["com.test.missing"] == nil)
        #expect(outcomes["com.test.notmas"] == nil)
        guard case .found(let candidate) = outcomes["com.test.a0"] else {
            Issue.record("expected a candidate")
            return
        }
        #expect(candidate.source == .appStore)
        #expect(candidate.version.short == "2.0")
        #expect(candidate.downloadURL == nil)
        #expect(candidate.minimumSystemVersion == "13.0")
    }

    /// An App Store page whose newest version-history entry reads `history`.
    private static func page(history: String) -> String {
        #"<html><script type="application/json" id="serialized-server-data">{"data":[{"data":{"shelfMapping":"#
            + #"{"mostRecentVersion":{"items":[{"primarySubtitle":"Version 9"}],"seeAllAction":{"pageData":"#
            + #"{"shelves":[{"items":[{"primarySubtitle":""# + history + #""}]}]}}}}}}]}</script></html>"#
    }

    private static let lookup = #"""
    {"results":[
     {"bundleId":"com.test.u","kind":"software","trackId":42,"version":"4.4.1","minimumOsVersion":"16.0",
      "trackViewUrl":"https://apps.apple.com/us/app/id42"},
     {"bundleId":"com.test.m","kind":"mac-software","trackId":7,"version":"2.0","minimumOsVersion":"13.0"}]}
    """#

    private func outcomes(page: String) async -> (StubAppReleaseHTTP, [String: AppReleaseSourceOutcome]) {
        let http = StubAppReleaseHTTP { url, _ in
            AppReleaseHTTPResponse(statusCode: 200, data: Data((url.host == "apps.apple.com" ? page : Self.lookup).utf8))
        }
        let apps = ["com.test.u", "com.test.m"].map {
            InstalledApp(bundleID: $0, name: $0, url: URL(fileURLWithPath: "/\($0).app"), isMAS: true)
        }
        return (http, await MASLookupSource(http: http, countryCode: "us").lookUp(apps))
    }

    @Test("an app sold for iPhone and Mac together is checked against its Mac App Store page")
    func iOSListingReadsMacPage() async {
        let (http, outcomes) = await outcomes(page: Self.page(history: "4.4.0"))
        guard case .found(let universal) = outcomes["com.test.u"], case .found(let mac) = outcomes["com.test.m"] else {
            Issue.record("expected two candidates, got \(outcomes)")
            return
        }
        #expect(universal.version.short == "4.4.0")
        #expect(universal.minimumSystemVersion == nil)
        #expect(mac.version.short == "2.0")
        #expect(mac.minimumSystemVersion == "13.0")
        #expect(http.requests.map(\.url.absoluteString).filter { $0.contains("apps.apple.com") }
            == ["https://apps.apple.com/us/app/id42?platform=mac"])
    }

    @Test("a Mac page without a readable version fails the check instead of using the iOS version")
    func unreadableMacPageFails() async {
        for page in ["<html></html>", Self.page(history: "Version 4.4.1"), Self.page(history: "")] {
            let (_, outcomes) = await outcomes(page: page)
            #expect(outcomes["com.test.u"] == .failed(MASLookupSource.unreadableMacVersion))
            guard case .found = outcomes["com.test.m"] else {
                Issue.record("the Mac listing should still be found")
                continue
            }
        }
    }
}
