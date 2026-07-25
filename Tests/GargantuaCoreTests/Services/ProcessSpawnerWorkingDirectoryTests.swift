import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessSpawner working directory")
struct ProcessSpawnerWorkingDirectoryTests {

    @Test("spawns the child in the user's home directory")
    func spawnsInHome() throws {
        let output = try DefaultProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: []
        )
        let reported = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        #expect(output.exitCode == 0)
        #expect(URL(fileURLWithPath: reported).resolvingSymlinksInPath().path == home)
    }

    @Test("the child can write into its working directory")
    func workingDirectoryIsWritable() throws {
        // The pnpm failure shape: a tool that drops a probe file into the cwd
        // and exits non-zero when that fails. Under the inherited `/` of a
        // Finder launch this exits 226 with EROFS.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gargantua-cwd-\(getpid())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let probeName = "gargantua-cwd-probe-\(getpid())"
        let tool = dir.appendingPathComponent("tool")
        try "#!/bin/sh\ntouch ./\(probeName) || exit 226\nrm -f ./\(probeName)\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let output = try DefaultProcessRunner().run(executable: tool, arguments: [])
        #expect(output.exitCode == 0)
    }
}
