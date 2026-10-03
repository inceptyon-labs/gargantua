import Foundation

/// A running command-line process with a unique executable name, for tests of
/// matching processes by executable name.
///
/// It is a copy of `/bin/sleep` re-signed ad hoc. An unmodified copy keeps
/// Apple's platform signature, and macOS intermittently SIGKILLs such a copy
/// when it runs from outside the system volume, which made these tests flaky.
final class ProbeProcess {
    let name: String
    private let directory: URL
    private let process = Process()

    init() throws {
        let suffix = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8))
        name = "gargantua-probe-\(suffix)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)

        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", binary.path]
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else {
            throw CocoaError(.executableNotLoadable)
        }

        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
