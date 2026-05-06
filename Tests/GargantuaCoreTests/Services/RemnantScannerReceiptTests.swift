import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantScanner + receipt evidence")
struct RemnantScannerReceiptTests {

    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        let outputs: [[String]: ProcessOutput]

        init(outputs: [[String]: ProcessOutput]) {
            self.outputs = outputs
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable _: URL, arguments: [String], timeout _: TimeInterval?) throws -> ProcessOutput {
            outputs[arguments] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemnantScannerReceiptTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func makeFile(_ relative: String, contents: String = "x") throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    @Test("appends receipt-evidence remnants alongside YAML-rule remnants")
    func receiptsSurfacedAsRemnants() throws {
        let fixture = try Fixture()
        let cacheFile = try fixture.makeFile("Library/Application Support/Docker/data.bin", contents: "abc")

        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(stdout: "com.docker.docker", stderr: "", exitCode: 0),
            ["--pkg-info", "com.docker.docker"]: ProcessOutput(
                stdout: """
                package-id: com.docker.docker
                version: 4.30.0
                volume: /
                location: /
                """,
                stderr: "",
                exitCode: 0
            ),
            // Use an absolute path stub: pkgutil emits relative paths, but
            // we emulate by making the file under fixture.root and then
            // having `--files` emit its path stripped of leading "/" so the
            // expander resolves it against `volume: /`.
            ["--files", "com.docker.docker"]: ProcessOutput(
                stdout: String(cacheFile.path.dropFirst()),
                stderr: "",
                exitCode: 0
            ),
        ])

        let expander = PackageReceiptExpander(runner: runner)
        let builder = ReceiptRemnantBuilder(
            protectedRoots: ProtectedRootPolicy(entries: [])
        )

        let scanner = RemnantScanner(rules: [])
            .withReceiptEvidence(expander: expander, builder: builder)

        let app = AppInfo(
            bundleID: "com.docker.docker",
            name: "Docker",
            bundlePath: "/Applications/Docker.app"
        )
        let plan = scanner.plan(for: app, includeAppBundle: false)

        #expect(plan.remnants.count == 1)
        let item = try #require(plan.remnants.first)
        #expect(item.path == cacheFile.path)
        #expect(item.tags.contains("pkgutil-bom"))
        #expect(item.ruleID == "pkgutil-bom:com.docker.docker")
        #expect(item.safety == .review)
    }

    @Test("YAML rules win when a path is matched by both a rule and a receipt")
    func ruleWinsOverReceiptForDuplicatePaths() throws {
        let fixture = try Fixture()
        let target = try fixture.makeFile("Library/Application Support/Docker/data.bin", contents: "abc")

        let rule = RemnantRule(
            id: "docker_support",
            name: "Docker support",
            category: .supportFiles,
            pathTemplates: [target.path],
            confidence: 90,
            explanation: "Docker support files left after uninstall.",
            source: SourceAttribution(name: "Docker", bundleID: "com.docker.docker"),
            appliesTo: AppScope(bundleIDs: ["com.docker.docker"])
        )

        let runner = StubRunner(outputs: [
            ["--pkgs"]: ProcessOutput(stdout: "com.docker.docker", stderr: "", exitCode: 0),
            ["--pkg-info", "com.docker.docker"]: ProcessOutput(
                stdout: "package-id: com.docker.docker\nversion: 4.30.0\nvolume: /\nlocation: /",
                stderr: "",
                exitCode: 0
            ),
            ["--files", "com.docker.docker"]: ProcessOutput(
                stdout: String(target.path.dropFirst()),
                stderr: "",
                exitCode: 0
            ),
        ])
        let expander = PackageReceiptExpander(runner: runner)

        let scanner = RemnantScanner(rules: [rule])
            .withReceiptEvidence(
                expander: expander,
                builder: ReceiptRemnantBuilder(protectedRoots: ProtectedRootPolicy(entries: []))
            )

        let app = AppInfo(
            bundleID: "com.docker.docker",
            name: "Docker",
            bundlePath: "/Applications/Docker.app"
        )
        let plan = scanner.plan(for: app, includeAppBundle: false)

        #expect(plan.remnants.count == 1)
        let item = try #require(plan.remnants.first)
        // The rule-derived item wins — its rule ID is the YAML rule ID, not
        // a `pkgutil-bom:` prefix.
        #expect(item.ruleID == "docker_support")
        #expect(!item.tags.contains("pkgutil-bom"))
    }

    @Test("scanner without a receipt expander behaves like the legacy YAML-only path")
    func backwardsCompatibleWhenExpanderAbsent() {
        let scanner = RemnantScanner(rules: [])
        let app = AppInfo(bundleID: "com.example.thing", name: "Thing", bundlePath: "/Applications/Thing.app")
        let plan = scanner.plan(for: app, includeAppBundle: false)
        #expect(plan.remnants.isEmpty)
    }
}
