import Foundation
import Testing
@testable import GargantuaCore

@Suite("PackageReceiptExpander")
struct PackageReceiptExpanderTests {
    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private let outputs: [[String]: ProcessOutput]
        private let defaultOutput: ProcessOutput

        init(
            outputs: [[String]: ProcessOutput],
            defaultOutput: ProcessOutput = ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        ) {
            self.outputs = outputs
            self.defaultOutput = defaultOutput
        }

        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(executable _: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: URL(fileURLWithPath: "/unused"), arguments: arguments, timeout: nil)
        }

        func run(executable _: URL, arguments: [String], timeout _: TimeInterval?) throws -> ProcessOutput {
            lock.lock()
            _calls.append(arguments)
            lock.unlock()
            return outputs[arguments] ?? defaultOutput
        }
    }

    private func app(bundleID: String, name: String) -> AppInfo {
        AppInfo(bundleID: bundleID, name: name, bundlePath: "/Applications/\(name).app")
    }

    @Test("expands matched packages into absolute candidate paths with provenance")
    func expandsMatchedPackages() {
        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(
                stdout: """
                com.apple.pkg.CoreTypes
                com.docker.docker
                com.docker.docker.helper
                com.example.unrelated
                """,
                stderr: "",
                exitCode: 0
            ),
            ["--pkg-info", "com.docker.docker"]: ProcessOutput(
                stdout: """
                package-id: com.docker.docker
                version: 4.30.0
                volume: /
                location: /
                install-time: 1735689600
                """,
                stderr: "",
                exitCode: 0
            ),
            ["--files", "com.docker.docker"]: ProcessOutput(
                stdout: """
                Library/Application Support/Docker
                Library/LaunchDaemons/com.docker.vmnetd.plist
                """,
                stderr: "",
                exitCode: 0
            ),
            ["--pkg-info", "com.docker.docker.helper"]: ProcessOutput(
                stdout: """
                package-id: com.docker.docker.helper
                version: 1.0.0
                volume: /
                location: /
                """,
                stderr: "",
                exitCode: 0
            ),
            ["--files", "com.docker.docker.helper"]: ProcessOutput(
                stdout: "Library/PrivilegedHelperTools/com.docker.helper",
                stderr: "",
                exitCode: 0
            ),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        let candidates = expander.expand(for: app(bundleID: "com.docker.docker", name: "Docker"))

        #expect(candidates.count == 3)
        #expect(candidates.map(\.path) == [
            "/Library/Application Support/Docker",
            "/Library/LaunchDaemons/com.docker.vmnetd.plist",
            "/Library/PrivilegedHelperTools/com.docker.helper",
        ])

        let primary = candidates.first
        #expect(primary?.pkgID == "com.docker.docker")
        #expect(primary?.pkgVersion == "4.30.0")
        #expect(primary?.installDate == Date(timeIntervalSince1970: 1_735_689_600))
    }

    @Test("never invokes pkgutil for system packages")
    func skipsSystemPackages() {
        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(
                stdout: "com.apple.pkg.CoreTypes\ncom.apple.pkg.GarageBand",
                stderr: "",
                exitCode: 0
            ),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        let candidates = expander.expand(for: app(bundleID: "com.apple.dt.Xcode", name: "Xcode"))

        #expect(candidates.isEmpty)
        // Only `--pkgs` should have been called — no per-package expansion for Apple receipts.
        #expect(runner.calls == [["--pkgs"]])
    }

    @Test("returns empty list when pkgutil --pkgs fails")
    func gracefulOnPkgutilFailure() {
        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(
                stdout: "",
                stderr: "boom",
                exitCode: 1
            ),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        let candidates = expander.expand(for: app(bundleID: "com.docker.docker", name: "Docker"))

        #expect(candidates.isEmpty)
    }

    @Test("caches pkgutil --pkgs across subsequent expansions")
    func cachesPackageList() {
        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(stdout: "com.example.foo", stderr: "", exitCode: 0),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        _ = expander.expand(for: app(bundleID: "com.example.foo", name: "Foo"))
        _ = expander.expand(for: app(bundleID: "com.example.foo", name: "Foo"))

        // Two expand calls, but only one --pkgs invocation thanks to caching.
        #expect(runner.calls.filter { $0 == ["--pkgs"] }.count == 1)
    }

    @Test("clearCache forces pkgutil --pkgs to be re-run")
    func clearCacheRefetches() {
        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(stdout: "com.example.foo", stderr: "", exitCode: 0),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        _ = expander.expand(for: app(bundleID: "com.example.foo", name: "Foo"))
        expander.clearCache()
        _ = expander.expand(for: app(bundleID: "com.example.foo", name: "Foo"))

        #expect(runner.calls.filter { $0 == ["--pkgs"] }.count == 2)
    }

    @Test("skips a matched package whose pkg-info pkgutil call fails")
    func skipsBrokenReceipt() {
        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(stdout: "com.example.broken", stderr: "", exitCode: 0),
            ["--pkg-info", "com.example.broken"]: ProcessOutput(
                stdout: "",
                stderr: "no receipt",
                exitCode: 1
            ),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        let candidates = expander.expand(for: app(bundleID: "com.example.broken", name: "Broken"))

        #expect(candidates.isEmpty)
    }
}
