import Foundation
import Testing
@testable import GargantuaCore

@Suite("CzkawkaOutputParser")
struct CzkawkaOutputParserTests {

    private let parser = CzkawkaOutputParser()

    @Test("empty-files: extracts paths and ignores headers")
    func parseEmptyFiles() {
        let output = """
        -------------------------------------------------Empty files-------------------------------------------------
        Found 3 empty files.
        /tmp/a.txt
        /tmp/b.log
        /Users/u/.cache/empty
        """

        let findings = parser.parse(output, category: .emptyFiles)

        #expect(findings.map(\.path) == ["/tmp/a.txt", "/tmp/b.log", "/Users/u/.cache/empty"])
        #expect(findings.allSatisfy { $0.groupID == nil })
        #expect(findings.allSatisfy { $0.reportedSize == 0 })
    }

    @Test("empty-folders: handles trailing blank line")
    func parseEmptyFolders() {
        let output = """
        Found 2 empty folders.
        /Users/u/old
        /Users/u/old/nested

        """

        let findings = parser.parse(output, category: .emptyFolders)
        #expect(findings.map(\.path) == ["/Users/u/old", "/Users/u/old/nested"])
    }

    @Test("invalid-symlinks: strips `  destination not found` suffix")
    func parseSymlinks() {
        let output = """
        Found 2 invalid symlinks.
        /Users/u/bad.link  Not existing destination
        /Users/u/another.link  Non-existent target
        """

        let findings = parser.parse(output, category: .brokenSymlinks)
        #expect(findings.map(\.path) == ["/Users/u/bad.link", "/Users/u/another.link"])
    }

    @Test("big-files: parses byte-count prefix")
    func parseBigFiles() {
        let output = """
        Found 3 biggest files.
        104857600 /Users/u/Movies/backup.dmg
        52428800 /Users/u/Downloads/installer.pkg
        26214400 /Users/u/Desktop/video.mov
        """

        let findings = parser.parse(output, category: .bigFiles)

        #expect(findings.map(\.path) == [
            "/Users/u/Movies/backup.dmg",
            "/Users/u/Downloads/installer.pkg",
            "/Users/u/Desktop/video.mov",
        ])
        #expect(findings.map(\.reportedSize) == [104_857_600, 52_428_800, 26_214_400])
    }

    @Test("big-files: tolerates `B` unit token after byte count")
    func parseBigFilesWithBUnit() {
        let output = """
        Found 1 biggest files.
        999999 B /Users/u/big.bin
        """

        let findings = parser.parse(output, category: .bigFiles)
        #expect(findings.map(\.path) == ["/Users/u/big.bin"])
        #expect(findings.first?.reportedSize == 999_999)
    }

    @Test("similar-images: groups paths between blank lines")
    func parseSimilarImages() {
        let output = """
        Found 4 similar images.
        /Users/u/photo1.jpg - 1920x1080 - 2.1 MB
        /Users/u/photo1-copy.jpg - 1920x1080 - 2.1 MB

        /Users/u/vacation/a.png - 800x600 - 500 KB
        /Users/u/vacation/b.png - 800x600 - 500 KB
        """

        let findings = parser.parse(output, category: .similarImages)

        #expect(findings.count == 4)
        #expect(findings[0].groupID == 0)
        #expect(findings[1].groupID == 0)
        #expect(findings[2].groupID == 1)
        #expect(findings[3].groupID == 1)
        #expect(findings.map(\.path) == [
            "/Users/u/photo1.jpg",
            "/Users/u/photo1-copy.jpg",
            "/Users/u/vacation/a.png",
            "/Users/u/vacation/b.png",
        ])
    }

    @Test("relative or non-absolute lines are ignored")
    func skipsNonAbsolutePaths() {
        let output = """
        Found 2 empty files.
        relative/path.txt
        /abs/valid.txt
        banner text
        """

        let findings = parser.parse(output, category: .emptyFiles)
        #expect(findings.map(\.path) == ["/abs/valid.txt"])
    }

    @Test("empty output yields zero findings")
    func emptyOutput() {
        #expect(parser.parse("", category: .emptyFiles).isEmpty)
    }
}
