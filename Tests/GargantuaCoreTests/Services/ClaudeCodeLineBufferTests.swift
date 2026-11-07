import Foundation
import Testing
@testable import GargantuaCore

@Suite("ClaudeCodeLineBuffer")
struct ClaudeCodeLineBufferTests {
    @Test("a Unicode line separator inside a JSON string does not split the record")
    func unicodeLineSeparatorStaysInsideTheRecord() {
        let lines = UncheckedSendableBox<[String]>([])
        let buffer = ClaudeCodeLineBuffer { lines.value.append($0) }
        // A plain string so the escapes become real U+2028 / U+2029 / U+0085.
        let record = "{\"type\":\"user\",\"name\":\"before\u{2028}after\u{2029}end\u{85}tail\"}"

        buffer.append(record)
        #expect(lines.value.isEmpty, "no LF yet, so nothing is complete")
        buffer.append("\n")

        #expect(lines.value == [record])
    }

    @Test("LF still ends a record, including across chunks")
    func lineFeedEndsRecords() {
        let lines = UncheckedSendableBox<[String]>([])
        let buffer = ClaudeCodeLineBuffer { lines.value.append($0) }

        buffer.append("{\"a\":1}\n{\"b\"")
        buffer.append(":2}\n")
        buffer.finish()

        #expect(lines.value == [#"{"a":1}"#, #"{"b":2}"#])
    }
}
