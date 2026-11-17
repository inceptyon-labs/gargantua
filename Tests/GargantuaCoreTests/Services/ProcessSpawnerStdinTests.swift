import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessSpawner stdin")
struct ProcessSpawnerStdinTests {

    @Test("the child's stdin is /dev/null, so a reader sees EOF instead of blocking")
    func stdinIsDevNull() throws {
        let started = Date()
        let output = try DefaultProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            timeout: 5
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout.isEmpty)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test("the child's stdin is the null device, whatever the parent's stdin is")
    func stdinIsNullDevice() throws {
        let output = try DefaultProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/stat"),
            arguments: ["-L", "-f", "%Sr", "/dev/stdin"],
            timeout: 5
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "null")
    }
}
