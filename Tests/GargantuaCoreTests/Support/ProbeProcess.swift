import Foundation

/// A running command-line process with a unique executable name, for tests of
/// matching processes by executable name.
///
/// The probe is a one-line C `sleep` compiled for the host with `xcrun clang`.
/// A copy of `/bin/sleep` doesn't work: it is an arm64e platform binary, so an
/// untouched copy is intermittently SIGKILLed outside the system volume, and an
/// ad hoc re-signed copy is a third-party arm64e binary, which macOS 15 (the
/// CI runner) refuses to run.
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
        guard let compiled = Self.compiledBinary else {
            throw CocoaError(.executableNotLoadable)
        }
        // A copy keeps its linker signature; only the file name changes.
        let binary = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: compiled, to: binary)

        process.executableURL = binary
        try process.run()
    }

    /// Compiled once per test run and copied per probe, so parallel tests don't
    /// each run the compiler.
    private static let compiledBinary: URL? = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-probe-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("probe.c")
        let binary = directory.appendingPathComponent("probe")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compile.arguments = ["clang", "-o", binary.path, source.path]
            try compile.run()
            compile.waitUntilExit()
            return compile.terminationStatus == 0 ? binary : nil
        } catch {
            return nil
        }
    }()

    func stop() {
        // Never launched (init threw before `run()`): nothing to wait for.
        guard process.processIdentifier != 0 else { return }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
