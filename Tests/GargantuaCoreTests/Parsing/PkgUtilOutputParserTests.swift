import Foundation
import Testing
@testable import GargantuaCore

@Suite("PkgUtilOutputParser")
struct PkgUtilOutputParserTests {
    private let parser = PkgUtilOutputParser()

    @Test("parses pkg-info into a receipt with version, volume, location, install date")
    func parsePackageInfoFull() {
        let raw = """
        package-id: com.docker.docker
        version: 4.30.0
        volume: /
        location: /
        install-time: 1735689600
        groups: com.docker.pkg-group
        """

        let receipt = parser.parsePackageInfo(raw)

        #expect(receipt?.pkgID == "com.docker.docker")
        #expect(receipt?.version == "4.30.0")
        #expect(receipt?.volume == "/")
        #expect(receipt?.installLocation == "/")
        #expect(receipt?.installDate == Date(timeIntervalSince1970: 1_735_689_600))
    }

    @Test("accepts legacy `install-location` key as a fallback for `location`")
    func parsePackageInfoLegacyKey() {
        let raw = """
        package-id: com.example.legacy
        install-location: /Applications
        """

        let receipt = parser.parsePackageInfo(raw)

        #expect(receipt?.installLocation == "/Applications")
    }

    @Test("returns nil when no package-id line is present")
    func parsePackageInfoMissingID() {
        #expect(parser.parsePackageInfo("") == nil)
        #expect(parser.parsePackageInfo("version: 1.0") == nil)
    }

    @Test("ignores blank lines and stray whitespace in pkg-info")
    func parsePackageInfoTolerantOfWhitespace() {
        let raw = """

           package-id:    com.example.tool

           version:   2.1.0
        """

        let receipt = parser.parsePackageInfo(raw)

        #expect(receipt?.pkgID == "com.example.tool")
        #expect(receipt?.version == "2.1.0")
    }

    @Test("parses files output into trimmed, non-empty BOM entries")
    func parseFiles() {
        let raw = """
        Library
        Library/Application Support
        Library/Application Support/Docker

           Library/LaunchDaemons/com.docker.vmnetd.plist
        """

        let entries = parser.parseFiles(raw)

        #expect(entries == [
            "Library",
            "Library/Application Support",
            "Library/Application Support/Docker",
            "Library/LaunchDaemons/com.docker.vmnetd.plist",
        ])
    }

    @Test("parses --pkgs output into a list of package IDs")
    func parsePackageList() {
        let raw = """
        com.apple.pkg.CoreTypes
        com.docker.docker
        com.example.misc
        """

        let pkgs = parser.parsePackageList(raw)

        #expect(pkgs == ["com.apple.pkg.CoreTypes", "com.docker.docker", "com.example.misc"])
    }

    @Test("absolutePath joins volume + location + relative entry and standardizes")
    func absolutePathResolution() {
        let receipt = PackageReceipt(
            pkgID: "com.docker.docker",
            volume: "/",
            installLocation: "/"
        )

        #expect(
            receipt.absolutePath(for: "Library/LaunchDaemons/com.docker.vmnetd.plist")
                == "/Library/LaunchDaemons/com.docker.vmnetd.plist"
        )
    }

    @Test("absolutePath honors a non-root install-location")
    func absolutePathWithInstallLocation() {
        let receipt = PackageReceipt(
            pkgID: "com.example.app",
            volume: "/",
            installLocation: "/Applications"
        )

        #expect(receipt.absolutePath(for: "Example.app/Contents/Info.plist")
            == "/Applications/Example.app/Contents/Info.plist")
    }
}
