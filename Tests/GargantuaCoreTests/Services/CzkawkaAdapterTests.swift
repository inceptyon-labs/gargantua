import Foundation
import Testing
@testable import GargantuaCore

@Suite("CzkawkaAdapter")
struct CzkawkaAdapterTests {

    // MARK: - Stub runner

    struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
    }

    /// Deterministic `ProcessRunner` that records calls and replays canned
    /// stdout per subcommand. Defaults to exit 0 and empty stderr.
    final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]

        init(outputs: [String: ProcessOutput]) {
            self.outputs = outputs
        }

        var calls: [StubCall] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            lock.lock()
            _calls.append(StubCall(executable: executable.path, arguments: arguments))
            lock.unlock()

            let subcommand = arguments.first ?? ""
            return outputs[subcommand] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    // MARK: - Fixture helpers

    static func makeTempFile(byteCount: Int = 64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("target.bin")
        try Data(repeating: 0xAB, count: byteCount).write(to: url)
        return url
    }
}
