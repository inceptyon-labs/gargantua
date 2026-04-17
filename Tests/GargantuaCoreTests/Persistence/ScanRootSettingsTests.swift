import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScanRootSettings")
struct ScanRootSettingsTests {
    @Test("Normalizes valid project paths")
    func normalizeScanRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ScanRootSettings.normalizedStrings(from: [
            "  ~/Projects  ",
            "\(home)/Projects",
            "/tmp/work",
            "",
            "relative/path",
            "/",
            "~",
            "~/",
        ])

        #expect(roots == ["~/Projects", "/tmp/work"])
    }

    @Test("Resolves URLs from normalized strings")
    func resolveScanRootURLs() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let urls = ScanRootSettings.resolvedURLs(from: ["~/Projects", "/tmp/work", "/"])

        #expect(urls.map(\.path) == ["\(home)/Projects", "/tmp/work"])
    }
}
