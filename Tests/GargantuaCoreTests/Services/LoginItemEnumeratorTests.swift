import Foundation
import Testing
@testable import GargantuaCore

@Suite("LoginItemEnumerator + SfltoolDumpbtmParser")
struct LoginItemEnumeratorTests {

    // MARK: - Parser

    @Test("Parses well-formed sfltool dumpbtm record")
    func parsesWellFormedRecord() {
        let output = """
        Records [2]:
        ==========================================
        Name: Foo Helper
        Identifier: com.example.foo.helper
        URL: file:///Applications/Foo.app/Contents/Library/LoginItems/Helper.app
        Team Identifier: ABCDE12345
        ==========================================
        Name: Bar
        Identifier: com.example.bar
        URL: file:///Applications/Bar.app
        Team Identifier: ZZZZZ99999
        """

        let records = SfltoolDumpbtmParser.parse(output)
        #expect(records.count == 2)

        let first = records[0]
        #expect(first.name == "Foo Helper")
        #expect(first.bundleIdentifier == "com.example.foo.helper")
        #expect(first.teamIdentifier == "ABCDE12345")
        #expect(first.url?.path == "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app")
    }

    @Test("Strips quoted values")
    func stripsQuotedValues() {
        let output = """
        ==========================================
        Name: \"Quoted Name\"
        Identifier: \"com.quoted.id\"
        """
        let records = SfltoolDumpbtmParser.parse(output)
        #expect(records.first?.name == "Quoted Name")
        #expect(records.first?.bundleIdentifier == "com.quoted.id")
    }

    @Test("Skips records with no name and no identifier")
    func skipsEmptyRecords() {
        let output = """
        ==========================================
        URL: file:///nowhere
        Team Identifier: AAA
        ==========================================
        """
        let records = SfltoolDumpbtmParser.parse(output)
        #expect(records.isEmpty)
    }

    @Test("Falls back to identifier when name is missing")
    func fallsBackToIdentifier() {
        let output = """
        ==========================================
        Identifier: com.example.only
        Team Identifier: BBB
        """
        let records = SfltoolDumpbtmParser.parse(output)
        #expect(records.count == 1)
        #expect(records.first?.name == "com.example.only")
    }

    @Test("Empty input yields empty records")
    func emptyInput() {
        #expect(SfltoolDumpbtmParser.parse("").isEmpty)
    }

    @Test("Tolerates blank-line separated blocks")
    func blankLineSeparated() {
        let output = """
        Name: First
        Identifier: com.first

        Name: Second
        Identifier: com.second
        """
        let records = SfltoolDumpbtmParser.parse(output)
        #expect(records.count == 2)
        #expect(records.map(\.name) == ["First", "Second"])
    }

    // MARK: - Enumerator

    @Test("Enumerator collapses empty parse to needsPrivileges = true")
    func emptyParseFlagsPrivileges() {
        let enumerator = DefaultLoginItemEnumerator(runner: { ("", 1) })
        let result = enumerator.enumerate()
        #expect(result.records.isEmpty)
        #expect(result.needsPrivileges)
    }

    @Test("Enumerator surfaces parsed records and clears needsPrivileges")
    func parsedRecordsClearPrivileges() {
        let stub = """
        ==========================================
        Name: Sample
        Identifier: com.sample
        Team Identifier: XYZ
        """
        let enumerator = DefaultLoginItemEnumerator(runner: { (stub, 0) })
        let result = enumerator.enumerate()
        #expect(result.records.count == 1)
        #expect(result.records.first?.name == "Sample")
        #expect(!result.needsPrivileges)
    }
}
