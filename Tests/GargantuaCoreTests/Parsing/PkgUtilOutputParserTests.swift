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

    // MARK: - parseFileInfo

    @Test("parseFileInfo returns one receipt per pkgid stanza")
    func parseFileInfoMultipleStanzas() {
        // Real pkgutil --file-info output: leading volume/path block (no
        // pkgid — gets skipped) followed by one stanza per owning package.
        let raw = """
        volume: /
        path: /System/Library/Frameworks/Foundation.framework

        pkgid: com.apple.files.data-template
        pkg-version: 26.5
        install-time: 1777666508
        uid: 0
        gid: 0
        mode: 40755

        pkgid: com.apple.pkg.CoreTypes.1900A28
        pkg-version: 1.0.0.0.1.1762585687
        install-time: 1772638705
        uid: 0
        gid: 0
        mode: 40755
        """

        let receipts = parser.parseFileInfo(raw)

        #expect(receipts.count == 2)
        #expect(receipts[0].pkgID == "com.apple.files.data-template")
        #expect(receipts[0].version == "26.5")
        #expect(receipts[0].installDate == Date(timeIntervalSince1970: 1_777_666_508))
        #expect(receipts[1].pkgID == "com.apple.pkg.CoreTypes.1900A28")
        #expect(receipts[1].version == "1.0.0.0.1.1762585687")
    }

    @Test("parseFileInfo returns empty when the path is not in any receipt")
    func parseFileInfoUnowned() {
        // pkgutil prints only the leading volume/path block when nothing
        // claims the path.
        let raw = """
        volume: /
        path: /usr/share/man/man1/pkgutil.1
        """

        #expect(parser.parseFileInfo(raw).isEmpty)
    }

    @Test("parseFileInfo accepts stanzas missing pkg-version or install-time")
    func parseFileInfoPartialStanza() {
        let raw = """
        pkgid: com.example.minimal
        """

        let receipts = parser.parseFileInfo(raw)

        #expect(receipts.count == 1)
        #expect(receipts[0].pkgID == "com.example.minimal")
        #expect(receipts[0].version == nil)
        #expect(receipts[0].installDate == nil)
    }

    @Test("parseFileInfo on empty stdout returns empty")
    func parseFileInfoEmpty() {
        #expect(parser.parseFileInfo("").isEmpty)
    }

    @Test("parseFileInfo tolerates CRLF line endings")
    func parseFileInfoCRLF() {
        let raw = "volume: /\r\npath: /Applications/Foo.app\r\n\r\npkgid: com.example.foo\r\npkg-version: 1.0\r\n"

        let receipts = parser.parseFileInfo(raw)

        #expect(receipts.count == 1)
        #expect(receipts[0].pkgID == "com.example.foo")
        #expect(receipts[0].version == "1.0")
    }

    @Test("parseFileInfo skips lines without a colon mid-stanza")
    func parseFileInfoSkipsMalformedLines() {
        let raw = """
        pkgid: com.example.foo
        garbage line with no colon
        pkg-version: 1.0
        """

        let receipts = parser.parseFileInfo(raw)

        #expect(receipts.count == 1)
        #expect(receipts[0].pkgID == "com.example.foo")
        #expect(receipts[0].version == "1.0")
    }

    @Test("parseFileInfo skips stanzas without a pkgid line")
    func parseFileInfoSkipsBlocksWithoutPkgID() {
        // First stanza is the volume/path header (no pkgid), the second is
        // a real receipt. Only the receipt should come back.
        let raw = """
        volume: /
        path: /Applications/Example.app

        pkgid: com.example.app
        pkg-version: 1.0
        """

        let receipts = parser.parseFileInfo(raw)

        #expect(receipts.count == 1)
        #expect(receipts[0].pkgID == "com.example.app")
    }
}
