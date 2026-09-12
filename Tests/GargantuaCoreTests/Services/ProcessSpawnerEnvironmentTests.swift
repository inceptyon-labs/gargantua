import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessSpawner child environment")
struct ProcessSpawnerEnvironmentTests {

    @Test("prepends the executable's directory to PATH")
    func prependsBinDir() {
        // A directory that won't already be on the test host's PATH, so the
        // dedup branch can't mask the prepend.
        let env = ProcessSpawner.childEnvironment(
            for: URL(fileURLWithPath: "/var/empty/gargantua-fake-bin/pnpm")
        )
        let path = env["PATH"] ?? ""
        #expect(path.hasPrefix("/var/empty/gargantua-fake-bin:"))
    }

    @Test("does not duplicate a directory already on PATH")
    func noDuplicate() {
        // Whatever the current process PATH is, re-resolving a binary that
        // lives in one of its segments must not prepend a second copy.
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let firstSegment = existing.split(separator: ":").first.map(String.init) ?? "/usr/bin"
        let env = ProcessSpawner.childEnvironment(
            for: URL(fileURLWithPath: "\(firstSegment)/sometool")
        )
        #expect(env["PATH"] == existing)
    }

    @Test("prepends the symlink target's directory when the binary is a shim")
    func prependsSymlinkTargetDir() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gargantua-shim-\(getpid())")
        let realBin = root.appendingPathComponent("real/bin", isDirectory: true)
        let shimBin = root.appendingPathComponent("shim", isDirectory: true)
        try fm.createDirectory(at: realBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: shimBin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // The real npm lives in real/bin (alongside node); shim/npm is a
        // symlink to it. PATH must include real/bin, not just shim.
        let target = realBin.appendingPathComponent("npm")
        try "".write(to: target, atomically: true, encoding: .utf8)
        let shim = shimBin.appendingPathComponent("npm")
        try fm.createSymbolicLink(at: shim, withDestinationURL: target)

        let env = ProcessSpawner.childEnvironment(for: shim)
        let path = env["PATH"] ?? ""
        #expect(path.split(separator: ":").contains(Substring(realBin.resolvingSymlinksInPath().path)))
        #expect(path.split(separator: ":").contains(Substring(shimBin.path)))
    }

    @Test("strips DYLD_* overrides from the child environment")
    func stripsDyldOverrides() throws {
        // The variable is set on this process for the duration of the test;
        // `childEnvironment` reads `ProcessInfo.processInfo.environment`,
        // which reflects `setenv` on Darwin.
        let key = "DYLD_INSERT_LIBRARIES"
        setenv(key, "/tmp/evil.dylib", 1)
        defer { unsetenv(key) }
        #expect(ProcessInfo.processInfo.environment[key] == "/tmp/evil.dylib")

        let env = ProcessSpawner.childEnvironment(for: URL(fileURLWithPath: "/bin/sh"))

        #expect(env[key] == nil)
        #expect(env.keys.contains { $0.hasPrefix("DYLD_") } == false)
        #expect(env["PATH"] != nil)
    }

    @Test("end-to-end: a node-shim-style sibling resolves via env")
    func siblingResolvesViaEnv() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gargantua-spawn-\(getpid())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // `helper` stands in for `node`: reachable only via PATH.
        let helper = dir.appendingPathComponent("helper")
        try "#!/bin/sh\necho resolved\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        // `tool` stands in for the `pnpm` shim: run by absolute path, but it
        // re-execs its sibling through `env`, which searches PATH.
        let tool = dir.appendingPathComponent("tool")
        try "#!/bin/sh\nexec env helper\n".write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let output = try DefaultProcessRunner().run(executable: tool, arguments: [])
        #expect(output.exitCode == 0)
        #expect(output.stdout == "resolved\n")
    }
}
