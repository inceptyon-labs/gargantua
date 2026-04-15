import Foundation
import Testing
@testable import GargantuaCore

@Suite("MoleRunnerConfig")
struct MoleRunnerConfigTests {
    @Test("Default timeout is 60 seconds")
    func defaultTimeout() {
        let config = MoleRunnerConfig()
        #expect(config.defaultTimeout == 60)
        #expect(config.binaryPath == nil)
    }

    @Test("Custom timeout and binary path")
    func customConfig() {
        let config = MoleRunnerConfig(defaultTimeout: 120, binaryPath: "/usr/local/bin/mo")
        #expect(config.defaultTimeout == 120)
        #expect(config.binaryPath == "/usr/local/bin/mo")
    }
}

@Suite("MoleRunResult")
struct MoleRunResultTests {
    @Test("succeeded is true when exit code is 0")
    func succeededOnZeroExit() {
        let result = MoleRunResult(stdout: Data(), stderr: Data(), exitCode: 0, duration: 1.0)
        #expect(result.succeeded)
    }

    @Test("succeeded is false for non-zero exit code")
    func failedOnNonZeroExit() {
        let result = MoleRunResult(stdout: Data(), stderr: Data(), exitCode: 1, duration: 1.0)
        #expect(!result.succeeded)
    }

    @Test("stdoutString decodes UTF-8 data")
    func stdoutStringDecoding() {
        let data = Data("{\"items\": []}".utf8)
        let result = MoleRunResult(stdout: data, stderr: Data(), exitCode: 0, duration: 0.5)
        #expect(result.stdoutString == "{\"items\": []}")
    }

    @Test("stderrString decodes UTF-8 data")
    func stderrStringDecoding() {
        let data = Data("error: file not found".utf8)
        let result = MoleRunResult(stdout: Data(), stderr: data, exitCode: 1, duration: 0.5)
        #expect(result.stderrString == "error: file not found")
    }

    @Test("empty stdout/stderr returns empty strings")
    func emptyOutputs() {
        let result = MoleRunResult(stdout: Data(), stderr: Data(), exitCode: 0, duration: 0.0)
        #expect(result.stdoutString == "")
        #expect(result.stderrString == "")
    }

    @Test("duration is preserved")
    func durationPreserved() {
        let result = MoleRunResult(stdout: Data(), stderr: Data(), exitCode: 0, duration: 3.14)
        #expect(result.duration == 3.14)
    }
}

@Suite("MoleError")
struct MoleErrorTests {
    @Test("binaryNotFound includes searched path")
    func binaryNotFoundDescription() {
        let error = MoleError.binaryNotFound(searchedPath: "/path/to/mo")
        #expect(error.errorDescription?.contains("/path/to/mo") == true)
    }

    @Test("timeout includes command name and seconds")
    func timeoutDescription() {
        let error = MoleError.timeout(command: "scan", seconds: 60)
        #expect(error.errorDescription?.contains("scan") == true)
        #expect(error.errorDescription?.contains("60") == true)
    }

    @Test("crashed includes command and exit code")
    func crashedDescription() {
        let error = MoleError.crashed(command: "clean", exitCode: 139, stderr: "segfault")
        #expect(error.errorDescription?.contains("clean") == true)
        #expect(error.errorDescription?.contains("139") == true)
    }

    @Test("executionFailed includes command and exit code")
    func executionFailedDescription() {
        let error = MoleError.executionFailed(command: "status", exitCode: 2, stderr: "bad arg")
        #expect(error.errorDescription?.contains("status") == true)
        #expect(error.errorDescription?.contains("2") == true)
    }
}

@Suite("MoleRunner")
struct MoleRunnerTests {
    @Test("resolveBinaryPath throws when explicit path does not exist")
    func explicitPathNotFound() {
        let config = MoleRunnerConfig(binaryPath: "/nonexistent/path/to/mo")
        let runner = MoleRunner(config: config)

        #expect(throws: MoleError.self) {
            try runner.resolveBinaryPath()
        }
    }

    @Test("resolveBinaryPath uses explicit path when it exists")
    func explicitPathUsed() throws {
        // Use a known-existing binary as a stand-in
        let config = MoleRunnerConfig(binaryPath: "/usr/bin/true")
        let runner = MoleRunner(config: config)
        let path = try runner.resolveBinaryPath()
        #expect(path == "/usr/bin/true")
    }

    @Test("run with real process succeeds")
    func runRealProcess() async throws {
        // Use /usr/bin/echo as a stand-in for the mo binary
        let config = MoleRunnerConfig(defaultTimeout: 10, binaryPath: "/bin/echo")
        let runner = MoleRunner(config: config)
        let result = try await runner.run(command: "hello", arguments: ["world"])
        #expect(result.succeeded)
        #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
        #expect(result.duration > 0)
    }

    @Test("run with non-zero exit throws executionFailed")
    func nonZeroExitThrows() async {
        let config = MoleRunnerConfig(defaultTimeout: 10, binaryPath: "/usr/bin/false")
        let runner = MoleRunner(config: config)

        do {
            _ = try await runner.run(command: "unused")
            Issue.record("Expected MoleError.executionFailed")
        } catch let error as MoleError {
            if case .executionFailed(_, let exitCode, _) = error {
                #expect(exitCode == 1)
            } else {
                Issue.record("Expected executionFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("run with timeout throws MoleError.timeout")
    func timeoutThrows() async {
        // sleep 10 with 1s timeout should timeout
        let config = MoleRunnerConfig(defaultTimeout: 1, binaryPath: "/bin/sleep")
        let runner = MoleRunner(config: config)

        do {
            _ = try await runner.run(command: "10")
            Issue.record("Expected MoleError.timeout")
        } catch let error as MoleError {
            if case .timeout(_, let seconds) = error {
                #expect(seconds == 1)
            } else {
                Issue.record("Expected timeout, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("run with missing binary throws binaryNotFound")
    func missingBinaryThrows() async {
        let config = MoleRunnerConfig(binaryPath: "/nonexistent/mo")
        let runner = MoleRunner(config: config)

        do {
            _ = try await runner.run(command: "scan")
            Issue.record("Expected MoleError.binaryNotFound")
        } catch let error as MoleError {
            if case .binaryNotFound(let path) = error {
                #expect(path == "/nonexistent/mo")
            } else {
                Issue.record("Expected binaryNotFound, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("custom timeout overrides default")
    func customTimeoutOverride() async {
        // sleep 10 with explicit 1s timeout
        let config = MoleRunnerConfig(defaultTimeout: 300, binaryPath: "/bin/sleep")
        let runner = MoleRunner(config: config)

        do {
            _ = try await runner.run(command: "10", timeout: 1)
            Issue.record("Expected timeout")
        } catch let error as MoleError {
            if case .timeout(_, let seconds) = error {
                #expect(seconds == 1)
            } else {
                Issue.record("Expected timeout, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
