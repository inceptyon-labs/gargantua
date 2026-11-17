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
                "{\"bundleId\":\"\($0)\",\"version\":\"2.0\",\"trackViewUrl\":\"https://apps.apple.com/app/\($0)\",\"minimumOsVersion\":\"13.0\"}"
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
}
