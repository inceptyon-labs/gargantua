import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@Suite("RuleApplicabilityProbe")
struct RuleApplicabilityProbeTests {

    // MARK: - Fixture helpers

    private static func makeFixture() throws -> FixtureTree {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleApplicabilityProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: Self.realpath(raw.path) ?? raw.path, isDirectory: true)
        return FixtureTree(root: root)
    }

    private static func realpath(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }

    private final class FixtureTree {
        let root: URL

        init(root: URL) {
            self.root = root
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func makeDir(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func makeFile(_ relative: String, contents: String = "") throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    // MARK: - Pattern → ecosystem mapping

    @Test("required(for:) maps known **/<leaf> patterns to their ecosystem")
    func patternEcosystemMapping() {
        #expect(RulePatternEcosystem.required(for: "**/node_modules") == .node)
        #expect(RulePatternEcosystem.required(for: "**/.next/cache") == .node)
        #expect(RulePatternEcosystem.required(for: "**/.tsbuildinfo") == .node)
        #expect(RulePatternEcosystem.required(for: "**/__pycache__") == .python)
        #expect(RulePatternEcosystem.required(for: "**/.venv") == .python)
        #expect(RulePatternEcosystem.required(for: "**/target") == .rust)
        #expect(RulePatternEcosystem.required(for: "**/.gradle") == .jvm)
        #expect(RulePatternEcosystem.required(for: "**/.zig-cache") == .zig)
        #expect(RulePatternEcosystem.required(for: "**/.terraform") == .terraform)
        #expect(RulePatternEcosystem.required(for: "**/.serverless") == .serverless)
        #expect(RulePatternEcosystem.required(for: "**/bin/Debug") == .dotnet)
        #expect(RulePatternEcosystem.required(for: "**/obj") == .dotnet)
    }

    @Test("required(for:) returns nil for ambiguous and concrete-prefix patterns")
    func patternEcosystemAmbiguous() {
        // `coverage` and `.nyc_output` straddle multiple ecosystems — let them run.
        #expect(RulePatternEcosystem.required(for: "**/coverage") == nil)
        #expect(RulePatternEcosystem.required(for: "**/.nyc_output") == nil)

        // Concrete-prefix patterns short-circuit on fileExists already; no need to filter.
        #expect(RulePatternEcosystem.required(for: "~/Projects/**/node_modules") == nil)
        #expect(RulePatternEcosystem.required(for: "~/.cargo/registry/cache") == nil)
        #expect(RulePatternEcosystem.required(for: "~/.npm/_cacache") == nil)
    }

    // MARK: - EcosystemProbe detection

    @Test("Detects node ecosystem from package.json at depth 1")
    func detectsNodeFromPackageJson() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeFile("my-app/package.json", contents: "{}")

        let detected = EcosystemProbe().detect(in: [fixture.root])
        #expect(detected.contains(.node))
    }

    @Test("Detects node ecosystem from a node_modules dir even without package.json")
    func detectsNodeFromNodeModules() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("project-a/node_modules")

        let detected = EcosystemProbe().detect(in: [fixture.root])
        #expect(detected.contains(.node))
    }

    @Test("Detects multiple ecosystems across sibling project dirs")
    func detectsMultipleEcosystems() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeFile("node-app/package.json", contents: "{}")
        try fixture.makeFile("rust-app/Cargo.toml", contents: "[package]")
        try fixture.makeFile("py-app/pyproject.toml", contents: "[project]")
        try fixture.makeFile("infra/main.tf", contents: "")
        try fixture.makeFile("zig-app/build.zig", contents: "")
        try fixture.makeFile("api/template.yaml", contents: "AWSTemplateFormatVersion:\n")
        // `samconfig.toml` would be a clearer signal; `template.yaml` alone is not enough,
        // so add the canonical Serverless config as well.
        try fixture.makeFile("api/serverless.yml", contents: "service: api")

        let detected = EcosystemProbe().detect(in: [fixture.root])
        #expect(detected.contains(.node))
        #expect(detected.contains(.rust))
        #expect(detected.contains(.python))
        #expect(detected.contains(.terraform))
        #expect(detected.contains(.zig))
        #expect(detected.contains(.serverless))
    }

    @Test("Detects dotnet from suffix-matched project files")
    func detectsDotnetFromCsproj() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeFile("svc/Svc.csproj", contents: "<Project/>")

        let detected = EcosystemProbe().detect(in: [fixture.root])
        #expect(detected.contains(.dotnet))
    }

    @Test("Returns empty when no signals present")
    func noSignalsReturnsEmpty() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeFile("notes/readme.md", contents: "# notes")
        try fixture.makeFile("photos/vacation.jpg", contents: "binary")

        let detected = EcosystemProbe().detect(in: [fixture.root])
        #expect(detected.isEmpty)
    }

    @Test("Skips descent into dependency directories so inner manifests don't pollute signals")
    func skipsDescentIntoDependencyDirs() throws {
        // A `package.json` buried inside a `node_modules` dependency shouldn't *only*
        // signal node — but the probe should also have stopped descending after seeing
        // node_modules itself, so we never reach the inner manifest.
        let fixture = try Self.makeFixture()
        try fixture.makeFile("project/node_modules/some-dep/package.json", contents: "{}")

        let detected = EcosystemProbe().detect(in: [fixture.root])
        // node ecosystem is detected via the node_modules dir signal.
        #expect(detected == [.node])
    }

    @Test("Honors maxDepth limit")
    func honorsMaxDepth() throws {
        let fixture = try Self.makeFixture()
        // package.json is 5 levels below the scan root; default depth=4 should miss it.
        try fixture.makeFile("a/b/c/d/e/package.json", contents: "{}")

        let shallow = EcosystemProbe(limits: .init(maxDepth: 4))
            .detect(in: [fixture.root])
        let deep = EcosystemProbe(limits: .init(maxDepth: 6))
            .detect(in: [fixture.root])

        #expect(!shallow.contains(.node))
        #expect(deep.contains(.node))
    }

    @Test("Returns empty for missing scan roots without crashing")
    func missingScanRoots() {
        let bogus = URL(fileURLWithPath: "/this/path/should/not/exist/zzz-\(UUID().uuidString)")
        let detected = EcosystemProbe().detect(in: [bogus])
        #expect(detected.isEmpty)
    }
}
