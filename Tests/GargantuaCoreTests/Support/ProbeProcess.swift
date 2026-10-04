import Foundation

/// A running command-line process with a unique executable name, for tests of
/// matching processes by executable name.
///
/// The probe is a C `sleep` compiled for the host with `xcrun clang`. It catches
/// catchable signals. A signal from its parent (the test runner, via `stop()`)
/// ends it. A signal from any other process is ignored and recorded on stderr,
/// so a stray sender can't end it; the record is printed on deinit and included
/// in `diagnosis`.
///
/// `init` waits until the probe has installed its handlers (it writes a `ready`
/// line), and relaunches a probe that a stray signal killed during startup.
///
/// A copy of `/bin/sleep` doesn't work: it is an arm64e platform binary, so an
/// untouched copy is intermittently SIGKILLed outside the system volume, and an
/// ad hoc re-signed copy is a third-party arm64e binary, which macOS 15 (the
/// CI runner) refuses to run.
final class ProbeProcess {
    let name: String
    private let directory: URL
    private var process = Process()
    private var stderrPipe = Pipe()
    private var stderrData = Data()
    private var startupEvents: [String] = []

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

        // A stray signal between exec and the probe's `sigaction` calls kills
        // it with the default action, so relaunch a probe that died before
        // reporting ready.
        let maxAttempts = 3
        for attempt in 1 ... maxAttempts {
            try launch(binary)
            let outcome = awaitReady()
            if outcome == .timedOut { startupEvents.append("attempt \(attempt) not ready after 2s") }
            if outcome != .exited { break }
            process.waitUntilExit()
            drainStderr()
            var event = "attempt \(attempt) died before ready: \(terminationDescription)"
            if !reportText.isEmpty { event += " (\(reportText.replacingOccurrences(of: "\n", with: " | ")))" }
            startupEvents.append(event)
            if attempt == maxAttempts { break }
            try? stderrPipe.fileHandleForReading.close()
        }
    }

    private enum Readiness { case ready, exited, timedOut }

    /// Starts a fresh process with fresh stderr data.
    private func launch(_ binary: URL) throws {
        process = Process()
        stderrPipe = Pipe()
        stderrData = Data()
        // Reads never block: `diagnosis` may run while the probe is alive, and
        // `deinit` may drain a pipe whose write end this process still holds.
        let fd = stderrPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        process.executableURL = binary
        process.standardError = stderrPipe
        try process.run()
    }

    /// Polls up to 2 seconds for the probe's `ready` line or its exit.
    private func awaitReady() -> Readiness {
        for _ in 0 ..< 400 {
            drainStderr()
            if hasReadyLine { return .ready }
            if !process.isRunning {
                drainStderr()
                return hasReadyLine ? .ready : .exited
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return .timedOut
    }

    private var hasReadyLine: Bool {
        stderrText.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "ready" }
    }

    /// Appends whatever stderr holds right now to `stderrData`; stops at EOF,
    /// when no data is pending, or on any error.
    private func drainStderr() {
        let fd = stderrPipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                stderrData.append(contentsOf: buffer[0 ..< count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private var stderrText: String {
        (String(bytes: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stderr without the `ready` line: the `signal ...` and `ignored signal ...` records.
    private var reportText: String {
        stderrText.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != "ready" }
            .joined(separator: "\n")
    }

    private var terminationDescription: String {
        process.terminationReason == .uncaughtSignal
            ? "signal \(process.terminationStatus)" : "status \(process.terminationStatus)"
    }

    /// How the probe is doing, for assertion messages, including any stderr
    /// written so far (ignored stray signals while it runs).
    var diagnosis: String {
        let pid = process.processIdentifier
        // `isRunning` stays true until Foundation reaps the child, so give a probe
        // that just died time to be reaped. Swift Testing evaluates the `#expect`
        // comment only on failure, so this delay is only paid when a test fails.
        var waited = 0
        while process.isRunning, waited < 20 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        drainStderr()
        let text = reportText
        let startup = startupEvents.isEmpty ? "" : "startup: \(startupEvents.joined(separator: "; ")); "
        if process.isRunning {
            return text.isEmpty
                ? "\(startup)probe pid \(pid) is still running"
                : "\(startup)probe pid \(pid) is still running; \(text)"
        }
        // The probe reported its own end only if a line starts with `signal `.
        if text.split(separator: "\n").contains(where: { $0.hasPrefix("signal ") }) {
            return "\(startup)probe pid \(pid) \(text)"
        }
        let ended: String
        if process.terminationReason == .uncaughtSignal {
            ended = "was killed by signal \(process.terminationStatus) without reporting a sender "
                + "(SIGKILL, or a signal that landed before its handlers were installed)"
        } else {
            ended = "exited with status \(process.terminationStatus)"
        }
        return text.isEmpty ? "\(startup)probe pid \(pid) \(ended)" : "\(startup)probe pid \(pid) \(text); \(ended)"
    }

    private static let cSource = """
    #include <errno.h>
    #include <libproc.h>
    #include <signal.h>
    #include <string.h>
    #include <unistd.h>

    static volatile pid_t parent = 0;

    static size_t append(char *dst, size_t at, size_t cap, const char *s) {
        while (*s && at + 1 < cap) dst[at++] = *s++;
        return at;
    }

    static size_t append_int(char *dst, size_t at, size_t cap, int v) {
        char tmp[16]; int i = sizeof tmp; tmp[--i] = 0;
        unsigned u = v < 0 ? -(unsigned)v : (unsigned)v;
        do { tmp[--i] = '0' + u % 10; u /= 10; } while (u && i > 1);
        if (v < 0) tmp[--i] = '-';
        return append(dst, at, cap, tmp + i);
    }

    static void on_signal(int sig, siginfo_t *info, void *ctx) {
        (void)ctx;
        int saved_errno = errno;
        int ours = info->si_pid == parent;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        path[0] = 0;
        if (proc_pidpath(info->si_pid, path, sizeof path) <= 0) strcpy(path, "?");
        char buf[PROC_PIDPATHINFO_MAXSIZE + 64];
        size_t n = 0, cap = sizeof buf;
        n = append(buf, n, cap, ours ? "signal " : "ignored signal ");
        n = append_int(buf, n, cap, sig);
        n = append(buf, n, cap, " from pid ");
        n = append_int(buf, n, cap, info->si_pid);
        n = append(buf, n, cap, " ");
        n = append(buf, n, cap, path);
        n = append(buf, n, cap, "\\n");
        write(2, buf, n);
        if (ours) _exit(128 + sig);
        errno = saved_errno;
    }

    int main(void) {
        parent = getppid();
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = on_signal;
        sa.sa_flags = SA_SIGINFO;
        sigfillset(&sa.sa_mask);
        int sigs[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGALRM };
        for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaction(sigs[i], &sa, 0);
        write(2, "ready\\n", 6);
        unsigned left = 30;
        while (left > 0) left = sleep(left);
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
        if process.isRunning {
            process.terminate()
            // A stopped probe never acts on SIGTERM; SIGKILL works on it.
            for _ in 0 ..< 200 where process.isRunning { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    deinit {
        stop()
        if process.processIdentifier != 0 {
            drainStderr()
            for event in startupEvents { print("probe \(name): \(event)") }
            for line in reportText.split(separator: "\n") where line.contains("ignored signal") {
                print("probe \(name): \(line)")
            }
        }
        try? stderrPipe.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
