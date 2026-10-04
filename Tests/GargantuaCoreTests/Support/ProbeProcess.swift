import Foundation

/// A running command-line process with a unique executable name, for tests of
/// matching processes by executable name.
///
/// The probe is a C `sleep` compiled for the host with `xcrun clang`. It catches
/// terminating signals and reports which signal ended it and who sent it, so a
/// failing test names the sender (see `diagnosis`).
///
/// A copy of `/bin/sleep` doesn't work: it is an arm64e platform binary, so an
/// untouched copy is intermittently SIGKILLed outside the system volume, and an
/// ad hoc re-signed copy is a third-party arm64e binary, which macOS 15 (the
/// CI runner) refuses to run.
final class ProbeProcess {
    let name: String
    private let directory: URL
    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrText: String?

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
        process.standardError = stderrPipe
        try process.run()
    }

    /// How the probe is doing, for assertion messages. While it runs this reads
    /// nothing from the pipe (a read would block); after exit it reads stderr once.
    var diagnosis: String {
        let pid = process.processIdentifier
        if process.isRunning { return "probe pid \(pid) is still running" }
        if stderrText == nil {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrText = (String(bytes: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = stderrText, !text.isEmpty { return "probe pid \(pid) \(text)" }
        if process.terminationReason == .uncaughtSignal {
            return "probe pid \(pid) was killed by uncatchable signal \(process.terminationStatus)"
        }
        return "probe pid \(pid) exited with status \(process.terminationStatus)"
    }

    private static let cSource = """
    #include <libproc.h>
    #include <signal.h>
    #include <string.h>
    #include <unistd.h>

    static void put(const char *s) { write(2, s, strlen(s)); }

    static void put_int(int v) {
        char buf[16]; int i = sizeof buf; buf[--i] = 0;
        unsigned u = v < 0 ? -(unsigned)v : (unsigned)v;
        do { buf[--i] = '0' + u % 10; u /= 10; } while (u && i > 1);
        if (v < 0) buf[--i] = '-';
        put(buf + i);
    }

    static void on_signal(int sig, siginfo_t *info, void *ctx) {
        (void)ctx;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        path[0] = 0;
        if (proc_pidpath(info->si_pid, path, sizeof path) <= 0) strcpy(path, "?");
        put("signal "); put_int(sig); put(" from pid "); put_int(info->si_pid); put(" "); put(path); put("\\n");
        _exit(128 + sig);
    }

    int main(void) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = on_signal;
        sa.sa_flags = SA_SIGINFO;
        int sigs[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGALRM };
        for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaction(sigs[i], &sa, 0);
        sleep(30);
        return 0;
    }
    """

    /// Compiled once per test run and copied per probe, so parallel tests don't
    /// each run the compiler.
    private static let compiledBinary: URL? = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-probe-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("probe.c")
        let binary = directory.appendingPathComponent("probe")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(ProbeProcess.cSource.utf8).write(to: source)
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
