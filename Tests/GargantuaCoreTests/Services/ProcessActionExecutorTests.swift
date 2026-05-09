import Darwin
import Foundation
import Testing
@testable import GargantuaCore

// swiftlint:disable file_length

private struct SignalCall: Equatable {
    let signal: Int32
    let pid: Int32
}

@Suite("ProcessActionExecutor")
@MainActor
// swiftlint:disable:next type_body_length
struct ProcessActionExecutorTests {

    // MARK: - Stubs

    private final class FakeSignaler: ProcessSignalSending, @unchecked Sendable {
        nonisolated(unsafe) private var _calls: [SignalCall] = []
        nonisolated(unsafe) private var _aliveResponses: [Bool] = []
        nonisolated(unsafe) private var _sendResponses: [Int32: [Int32]] = [:] // signal → errno queue
        nonisolated(unsafe) private var _startTimeResponses: [UInt64?] = []
        nonisolated(unsafe) private var _defaultStartTime: UInt64? = 1_000
        private let lock = NSLock()

        var calls: [SignalCall] { lock.withLock { _calls } }

        /// Queue alive-probe responses, popped in order. If exhausted, returns
        /// `false` (process gone).
        func enqueueAlive(_ values: [Bool]) {
            lock.withLock { _aliveResponses.append(contentsOf: values) }
        }

        /// Queue errno responses for a given signal, popped in order.
        func enqueueSendErrno(_ value: Int32, forSignal signal: Int32) {
            lock.withLock {
                var existing = _sendResponses[signal] ?? []
                existing.append(value)
                _sendResponses[signal] = existing
            }
        }

        /// Queue start-time responses, popped in order. Each successive
        /// `startTime(pid:)` call drains one. When exhausted, returns the
        /// configured default (matches the snapshot's start time so identity
        /// checks pass).
        func enqueueStartTime(_ values: [UInt64?]) {
            lock.withLock { _startTimeResponses.append(contentsOf: values) }
        }

        /// Set the default start time returned once the queue is exhausted.
        /// Tests that don't care about the recycle-detection branch can
        /// leave this at its default.
        func setDefaultStartTime(_ value: UInt64?) {
            lock.withLock { _defaultStartTime = value }
        }

        func send(_ signal: Int32, to pid: Int32) -> ProcessSignalResult {
            lock.withLock { _calls.append(SignalCall(signal: signal, pid: pid)) }
            let errno = lock.withLock { () -> Int32 in
                guard var queue = _sendResponses[signal], !queue.isEmpty else { return 0 }
                let value = queue.removeFirst()
                _sendResponses[signal] = queue
                return value
            }
            return ProcessSignalResult(errno: errno, signal: signal)
        }

        func isAlive(pid _: Int32) -> Bool {
            lock.withLock {
                guard !_aliveResponses.isEmpty else { return false }
                return _aliveResponses.removeFirst()
            }
        }

        func startTime(pid _: Int32) -> UInt64? {
            lock.withLock {
                guard !_startTimeResponses.isEmpty else { return _defaultStartTime }
                return _startTimeResponses.removeFirst()
            }
        }
    }

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(
        pid: Int32 = 4242,
        startTimeUnixSeconds: UInt64 = 1_000,
        command: String = "tool",
        executablePath: String? = "/usr/local/bin/tool",
        launchSource: ProcessLaunchSource = .userSession,
        launchConfidence: LaunchSourceConfidence = .unknown,
        safety: SafetyLevel = .review
    ) -> ProcessItem {
        ProcessItem(
            id: "\(pid)|\(startTimeUnixSeconds)|\(executablePath ?? command)",
            pid: pid,
            parentPID: 1,
            startTimeUnixSeconds: startTimeUnixSeconds,
            command: command,
            uid: 501,
            owningUser: "me",
            executablePath: executablePath,
            cpuFraction: 0.1,
            residentBytes: 8_000_000,
            identity: nil,
            launchSource: launchSource,
            launchConfidence: launchConfidence,
            safety: safety,
            reasons: [],
            explanation: "Test process"
        )
    }

    private func makeExecutor(
        signaler: FakeSignaler = FakeSignaler(),
        auditDir: URL,
        termGraceNs: UInt64 = 0,
        killGraceNs: UInt64 = 0
    ) -> (DefaultProcessActionExecutor, AuditWriter) {
        let writer = AuditWriter(logDirectory: auditDir)
        let executor = DefaultProcessActionExecutor(
            signaler: signaler,
            audit: writer,
            termGraceNanoseconds: termGraceNs,
            killGraceNanoseconds: killGraceNs,
            now: { Date(timeIntervalSince1970: 1_715_000_000) },
            sleep: { _ in }
        )
        return (executor, writer)
    }

    // MARK: - Stop happy paths

    @Test("SIGTERM that brings down the process records SIGTERM in the audit")
    func termSucceedsRecordsTerm() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        // After SIGTERM the process is gone.
        signaler.enqueueAlive([false])
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem())

        #expect(outcome.succeeded)
        #expect(outcome.action == .stop)
        #expect(outcome.error == nil)
        #expect(signaler.calls == [.init(signal: SIGTERM, pid: 4242)])

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].tool == "kill")
        #expect(entries[0].command == "stop")
        #expect(entries[0].kind == .command)
        #expect(entries[0].cleanupMethod == .toolNative)
        #expect(entries[0].commandArguments == ["-\(SIGTERM)", "4242"])
        #expect(entries[0].commandExitCode == 0)
    }

    @Test("SIGTERM that fails to land escalates to SIGKILL and records the escalation chain")
    func termSurvivesEscalatesToKill() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        // Alive after SIGTERM, gone after SIGKILL.
        signaler.enqueueAlive([true, false])
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem())

        #expect(outcome.succeeded)
        #expect(signaler.calls == [
            .init(signal: SIGTERM, pid: 4242),
            .init(signal: SIGKILL, pid: 4242),
        ])

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        // Audit must surface the full escalation chain so the forensic
        // reader sees both the cooperative attempt and the forced kill.
        #expect(entries[0].commandArguments == [
            "-\(SIGTERM)", "4242",
            "-\(SIGKILL)", "4242",
        ])
        #expect(entries[0].commandExitCode == 0)
    }

    @Test("Process gone before the click still audits SIGTERM with ESRCH as the result code")
    func processGoneBeforeFirstSignal() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        signaler.enqueueSendErrno(ESRCH, forSignal: SIGTERM)
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem())

        #expect(outcome.succeeded)
        // No alive probe, no SIGKILL — ESRCH on first SIGTERM short-circuits.
        #expect(signaler.calls == [.init(signal: SIGTERM, pid: 4242)])
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].commandArguments == ["-\(SIGTERM)", "4242"])
        // ESRCH (not 0) — audit must distinguish "delivered" from "already gone".
        #expect(entries[0].commandExitCode == ESRCH)
    }

    // MARK: - Stop PID-recycling defense

    @Test("PID recycle BEFORE SIGTERM short-circuits and never sends a signal")
    func pidRecycleBeforeTermAborts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        // Pre-flight start time is for a different process.
        signaler.enqueueStartTime([9_999])
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(startTimeUnixSeconds: 1_000))

        #expect(outcome.succeeded)
        // Critical: no signal was sent — we declined to kill a stranger.
        #expect(signaler.calls.isEmpty)
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].commandExitCode == ESRCH)
    }

    @Test("PID recycle BEFORE SIGKILL escalation aborts without sending SIGKILL")
    func pidRecycleBeforeKillAborts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        // Pre-SIGTERM check matches; post-grace check shows recycled PID.
        signaler.enqueueStartTime([1_000, 9_999])
        signaler.enqueueAlive([true])
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(startTimeUnixSeconds: 1_000))

        #expect(outcome.succeeded)
        // Only the SIGTERM was sent — SIGKILL was suppressed.
        #expect(signaler.calls == [.init(signal: SIGTERM, pid: 4242)])
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        // Recorded as a SIGTERM-only success.
        #expect(entries[0].commandArguments == ["-\(SIGTERM)", "4242"])
    }

    // MARK: - Cancellation

    @Test("Task cancellation between SIGTERM and SIGKILL stops the escalation")
    func cancellationBetweenTermAndKill() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let writer = AuditWriter(logDirectory: dir)
        let executor = DefaultProcessActionExecutor(
            signaler: signaler,
            audit: writer,
            termGraceNanoseconds: 0,
            killGraceNanoseconds: 0,
            now: { Date(timeIntervalSince1970: 1_715_000_000) },
            // Sleep cancels the task it's running inside — which is the
            // detached child below, NOT this test's task. That mirrors the
            // production case where the user dismisses the view (cancelling
            // the row's action task) during the grace window.
            sleep: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )

        let item = makeItem()
        let outcome = await Task { @MainActor in
            await executor.stop(item)
        }.value

        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("cancelled") == true)
        // SIGKILL must NOT have been sent.
        #expect(signaler.calls == [.init(signal: SIGTERM, pid: 4242)])
    }

    @Test("SIGKILL fails (EPERM) records the escalation chain with kill's errno")
    func killFailsRecordsErrno() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        signaler.enqueueAlive([true]) // survives SIGTERM
        signaler.enqueueSendErrno(EPERM, forSignal: SIGKILL)
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem())

        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("SIGKILL failed") == true)
        let entries = try writer.readEntries()
        #expect(entries[0].commandExitCode == EPERM)
        #expect(entries[0].commandArguments == [
            "-\(SIGTERM)", "4242",
            "-\(SIGKILL)", "4242",
        ])
    }

    @Test("Process surviving SIGKILL records failure with negative exit code")
    func processSurvivesKill() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        signaler.enqueueAlive([true, true]) // survives both
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem())

        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("still running") == true)
        let entries = try writer.readEntries()
        #expect(entries[0].commandExitCode == -1)
    }

    // MARK: - Stop refusals

    @Test("Protected items refuse stop and write no audit entry")
    func protectedItemRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(safety: .protected_))

        #expect(!outcome.succeeded)
        #expect(outcome.error == ProcessActionRefusal.protectedItem.errorDescription)
        #expect(signaler.calls.isEmpty)
        // No audit row — the refusal never reached `kill(2)`, so there is
        // nothing forensic to record.
        let entries = (try? writer.readEntries()) ?? []
        #expect(entries.isEmpty)
    }

    @Test("Processes under /System/ refuse stop")
    func systemPathRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, _) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(executablePath: "/System/Library/PrivateFrameworks/Foo.framework/foo"))

        #expect(!outcome.succeeded)
        #expect(outcome.error == ProcessActionRefusal.systemPath.errorDescription)
        #expect(signaler.calls.isEmpty)
    }

    @Test("PID 1 (launchd) refuses stop")
    func launchdRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, _) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(pid: 1))

        #expect(!outcome.succeeded)
        #expect(outcome.error == ProcessActionRefusal.kernelOrInit.errorDescription)
        #expect(signaler.calls.isEmpty)
    }

    @Test("PID 0 (kernel task) refuses stop")
    func kernelTaskRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, _) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(pid: 0))

        #expect(!outcome.succeeded)
        #expect(outcome.error == ProcessActionRefusal.kernelOrInit.errorDescription)
        #expect(signaler.calls.isEmpty)
    }

    @Test("Refusal precedence: protected outranks system path")
    func protectedOutranksSystemPath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, _) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(
            executablePath: "/System/Library/PrivateFrameworks/Foo.framework/foo",
            safety: .protected_
        ))

        #expect(outcome.error == ProcessActionRefusal.protectedItem.errorDescription)
    }

    // MARK: - Remove source

    @Test("Remove source on a launchd-backed process returns the plist path for navigation")
    func removeSourceRoutes() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let item = makeItem(
            launchSource: .launchd(domain: .userAgent, label: "com.acme.tool", plistPath: "/Users/me/Library/LaunchAgents/com.acme.tool.plist"),
            launchConfidence: .exact
        )
        let outcome = await executor.removeSource(item)

        #expect(outcome.succeeded)
        #expect(outcome.routedPlistPath == "/Users/me/Library/LaunchAgents/com.acme.tool.plist")
        // No audit — the actual mutation runs through the Background Items
        // pane, which logs its own entry. Double-logging here would muddy
        // the forensic chain.
        let entries = (try? writer.readEntries()) ?? []
        #expect(entries.isEmpty)
    }

    @Test("Remove source on a protected process refuses up front, no routing")
    func removeSourceProtectedRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, _) = makeExecutor(signaler: signaler, auditDir: dir)

        let item = makeItem(
            launchSource: .launchd(
                domain: .systemDaemon,
                label: "com.apple.thing",
                plistPath: "/Library/LaunchDaemons/com.apple.thing.plist"
            ),
            launchConfidence: .exact,
            safety: .protected_
        )
        let outcome = await executor.removeSource(item)

        #expect(!outcome.succeeded)
        #expect(outcome.routedPlistPath == nil)
        #expect(outcome.error == ProcessActionRefusal.protectedItem.errorDescription)
    }

    @Test("Stop on a process with no executablePath records the command in the audit files")
    func stopWithoutExecutablePath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        signaler.enqueueAlive([false])
        let (executor, writer) = makeExecutor(signaler: signaler, auditDir: dir)

        let outcome = await executor.stop(makeItem(executablePath: nil))

        #expect(outcome.succeeded)
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        // When the process has no executable path (kernel task introspection
        // failure, sandbox restriction), audit falls back to command name.
        #expect(entries[0].files.first?.path == "tool")
    }

    @Test("Remove source on a heuristic match refuses with no plist routing")
    func removeSourceHeuristicRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signaler = FakeSignaler()
        let (executor, _) = makeExecutor(signaler: signaler, auditDir: dir)

        let item = makeItem(
            launchSource: .launchd(domain: .userAgent, label: "com.acme.tool", plistPath: "/Users/me/Library/LaunchAgents/com.acme.tool.plist"),
            launchConfidence: .heuristic
        )
        let outcome = await executor.removeSource(item)

        #expect(!outcome.succeeded)
        #expect(outcome.routedPlistPath == nil)
        #expect(outcome.error == ProcessActionRefusal.unsupportedRemoveSource.errorDescription)
    }
}
