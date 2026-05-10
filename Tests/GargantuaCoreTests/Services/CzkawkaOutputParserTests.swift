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

    // MARK: - czkawka 11.x output formats

    //
    // czkawka 11 changed several subcommands to emit quoted paths, plus a
    // human-readable byte count for `big`. These tests use real samples from
    // czkawka 11.0.1 to lock in the parser against silent regressions like the
    // one where every category except empty-folders dropped to zero findings.

    @Test("v11 empty-files: paths are quoted")
    func parseEmptyFilesV11() {
        let output = """
        Results of searching ["/Users/jason/dev"] with excluded paths [] and excluded items []
        (Before optimizations - included paths: ["/Users/jason/dev"], excluded paths: [])
        Found 2 empty files.
        "/Users/jason/dev/foo.d.ts"
        "/Users/jason/dev/bar.d.ts"
        """

        let findings = parser.parse(output, category: .emptyFiles)
        #expect(findings.map(\.path) == [
            "/Users/jason/dev/foo.d.ts",
            "/Users/jason/dev/bar.d.ts",
        ])
    }

    @Test("v11 temp-files: paths are quoted")
    func parseTempV11() {
        let output = """
        Found 2 temporary files.
        "/Users/jason/dev/.dart_tool/build/foo.part"
        "/Users/jason/dev/web/.DS_Store"
        """

        let findings = parser.parse(output, category: .temporaryFiles)
        #expect(findings.map(\.path) == [
            "/Users/jason/dev/.dart_tool/build/foo.part",
            "/Users/jason/dev/web/.DS_Store",
        ])
    }

    @Test("v11 big-files: human-readable size with paren byte count")
    func parseBigFilesV11() {
        let output = """
        Found 2 biggest files.
        137.16 MiB (143819976) - "/Users/jason/dev/build/Gargantua.dSYM/DWARF/Gargantua"
        125.30 MiB (131382896) - "/Users/jason/dev/lib/armeabi-v7a/libflutter.so"
        """

        let findings = parser.parse(output, category: .bigFiles)
        #expect(findings.map(\.path) == [
            "/Users/jason/dev/build/Gargantua.dSYM/DWARF/Gargantua",
            "/Users/jason/dev/lib/armeabi-v7a/libflutter.so",
        ])
        #expect(findings.map(\.reportedSize) == [143_819_976, 131_382_896])
    }

    @Test("v11 symlinks: path is quoted, target follows after tabs/spaces")
    func parseSymlinksV11() {
        let output = """
        Found 2 invalid symlinks.
        "/Users/jason/dev/.next/node_modules/better-sqlite3"\t\t"../node_modules/better-sqlite3"\t\tNon Existent File
        "/Users/jason/dev/node_modules/.pnpm/aggregate-error"\t\t"../aggregate-error@3.1.0"\t\tNon Existent File
        """

        let findings = parser.parse(output, category: .brokenSymlinks)
        #expect(findings.map(\.path) == [
            "/Users/jason/dev/.next/node_modules/better-sqlite3",
            "/Users/jason/dev/node_modules/.pnpm/aggregate-error",
        ])
    }

    @Test("v11 broken-files: quoted path with ` - reason` suffix")
    func parseBrokenV11() {
        let output = """
        Found 2 broken files.
        "/Users/jason/dev/web/public/clean-arc.png" - Format error decoding Png: Invalid PNG signature.
        "/Users/jason/dev/web/public/dotted-trail.png" - Format error decoding Png: Invalid PNG signature.
        """

        let findings = parser.parse(output, category: .brokenFiles)
        #expect(findings.map(\.path) == [
            "/Users/jason/dev/web/public/clean-arc.png",
            "/Users/jason/dev/web/public/dotted-trail.png",
        ])
    }

    @Test("v11 similar-images: quoted paths with similarity tier; blank-line group boundaries")
    func parseSimilarImagesV11() {
        let output = """
        357 images which have similar friends

        Found 3 images which have similar friends
        "/Users/jason/dev/test-results/a/test-finished-1.png" - 1280x720 - 20.04 KiB - Original
        "/Users/jason/dev/test-results/b/test-finished-1.png" - 1280x720 - 20.04 KiB - Original
        "/Users/jason/dev/test-results/c/test-finished-1.png" - 1280x720 - 20.04 KiB - Original

        Found 2 images which have similar friends
        "/Users/jason/dev/test-results/x/test-finished-1.png" - 1280x720 - 17.90 KiB - Original
        "/Users/jason/dev/test-results/y/test-finished-1.png" - 1280x720 - 17.90 KiB - Original
        """

        let findings = parser.parse(output, category: .similarImages)

        #expect(findings.count == 5)
        #expect(findings.map(\.path) == [
            "/Users/jason/dev/test-results/a/test-finished-1.png",
            "/Users/jason/dev/test-results/b/test-finished-1.png",
            "/Users/jason/dev/test-results/c/test-finished-1.png",
            "/Users/jason/dev/test-results/x/test-finished-1.png",
            "/Users/jason/dev/test-results/y/test-finished-1.png",
        ])
        // Group boundary: blank line between the two `Found N` blocks closes
        // the first group and opens the second.
        #expect(findings[0].groupID == 0)
        #expect(findings[2].groupID == 0)
        #expect(findings[3].groupID == 1)
        #expect(findings[4].groupID == 1)
    }

    @Test("v11 banner lines and 'Cannot open dir' warnings are not parsed as findings")
    func skipsV11BannersAndWarnings() {
        let output = """
        Results of searching ["/Users/jason/dev"] with excluded paths [] and excluded items []
        (Before optimizations - included paths: ["/Users/jason/dev"], excluded paths: [])
        Found 1 empty files.
        "/Users/jason/dev/legit.txt"
        -------------------------------WARNINGS--------------------------------
        Cannot open dir /Users/jason/Desktop, reason Operation not permitted (os error 1)
        ---------------------------END OF WARNINGS-----------------------------
        """

        let findings = parser.parse(output, category: .emptyFiles)
        #expect(findings.map(\.path) == ["/Users/jason/dev/legit.txt"])
    }
}
