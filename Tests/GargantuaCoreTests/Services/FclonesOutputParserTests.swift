import Foundation
import Testing
@testable import GargantuaCore

@Suite("FclonesOutputParser")
struct FclonesOutputParserTests {

    private let parser = FclonesOutputParser()

    @Test("parses canonical header + groups JSON into duplicate groups")
    func parsesCanonicalReport() throws {
        let json = """
        {
          "header": {
            "version": "0.34.0",
            "timestamp": "2026-04-17T12:00:00Z",
            "command": "fclones group --format json /tmp",
            "base_dir": "/tmp"
          },
          "groups": [
            {
              "file_len": 524288,
              "file_hash": "abc123def456",
              "files": [
                "/Users/u/Downloads/installer.dmg",
                "/Users/u/Desktop/installer.dmg"
              ]
            },
            {
              "file_len": 12345,
              "file_hash": "fedcba987654",
              "files": [
                "/Users/u/Documents/a.pdf",
                "/Users/u/Documents/copies/a.pdf",
                "/Users/u/Desktop/a.pdf"
              ]
            }
          ]
        }
        """

        let groups = try parser.parse(json)

        #expect(groups.count == 2)
        #expect(groups[0].id == 0)
        #expect(groups[0].fileLen == 524_288)
        #expect(groups[0].fileHash == "abc123def456")
        #expect(groups[0].paths == [
            "/Users/u/Downloads/installer.dmg",
            "/Users/u/Desktop/installer.dmg",
        ])
        #expect(groups[1].id == 1)
        #expect(groups[1].paths.count == 3)
    }

    @Test("empty groups array yields zero duplicate groups")
    func emptyGroupsArray() throws {
        let json = #"""
        { "header": {"version": "0.34.0"}, "groups": [] }
        """#

        let groups = try parser.parse(json)
        #expect(groups.isEmpty)
    }

    @Test("whitespace-only output yields zero duplicate groups")
    func whitespaceOutput() throws {
        #expect(try parser.parse("").isEmpty)
        #expect(try parser.parse("   \n\t  \n").isEmpty)
    }

    @Test("invalid JSON throws invalidJSON")
    func invalidJSONThrows() {
        #expect(throws: FclonesOutputParser.ParseError.self) {
            _ = try parser.parse("{not valid json")
        }
    }

    @Test("single-path groups are filtered out (a group of one is not a duplicate)")
    func filtersSingletonGroups() throws {
        let json = """
        {
          "header": {},
          "groups": [
            { "file_len": 10, "file_hash": "h1", "files": ["/only/one"] },
            { "file_len": 20, "file_hash": "h2", "files": ["/a", "/b"] }
          ]
        }
        """

        let groups = try parser.parse(json)
        #expect(groups.count == 1)
        #expect(groups[0].fileHash == "h2")
        // Enumeration index preserved: the surviving group was at index 1.
        #expect(groups[0].id == 1)
    }
}
