import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultProcessRunner")
struct DefaultProcessRunnerTests {

    @Test("Captures large stdout payload byte-for-byte without deadlock")
    func largeStdoutCapture() throws {
        let runner = DefaultProcessRunner()
        let byteCount = 100_000
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes | head -c \(byteCount)"]
        )

        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == byteCount)
        // `yes` emits "y\n" repeatedly. With an even byteCount, the capture
        // should start with "y" and end with "\n".
        let bytes = Array(output.stdout.utf8)
        #expect(bytes.first == UInt8(ascii: "y"))
        #expect(bytes.last == UInt8(ascii: "\n"))
    }
}
