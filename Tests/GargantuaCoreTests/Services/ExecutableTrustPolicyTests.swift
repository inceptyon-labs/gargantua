import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@Suite("ExecutableTrustPolicy")
struct ExecutableTrustPolicyTests {
    private static func makeScratchScript(mode: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutableTrustPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tool")
        try "#!/bin/sh\necho ran\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private static func record(mode: mode_t, uid: uid_t) -> stat {
        var info = stat()
        info.st_mode = mode
        info.st_uid = uid
        return info
    }

    @Test("a 755 file owned by the current user passes")
    func ownFileNotWritableByOthersPasses() throws {
        let url = try Self.makeScratchScript(mode: 0o755)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ExecutableTrustPolicy.verify(url)
    }

    @Test("a root-owned system binary passes")
    func rootOwnedPasses() throws {
        try ExecutableTrustPolicy.verify(URL(fileURLWithPath: "/bin/sh"))
    }

    @Test("a group- or world-writable file is refused")
    func writableByOthersRefused() throws {
        for mode in [0o775, 0o757, 0o777] {
            let url = try Self.makeScratchScript(mode: mode)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(throws: ExecutableTrustPolicy.Violation.writableByOthers(mode: mode_t(mode))) {
                try ExecutableTrustPolicy.verify(url)
            }
        }
    }

    @Test("a file owned by another non-root user is refused")
    func otherOwnerRefused() {
        let info = Self.record(mode: S_IFREG | 0o755, uid: 502)

        #expect(throws: ExecutableTrustPolicy.Violation.untrustedOwner(uid: 502)) {
            try ExecutableTrustPolicy.verify(info, currentUser: 501)
        }
    }

    @Test("root ownership is accepted for any current user")
    func rootOwnerAccepted() throws {
        try ExecutableTrustPolicy.verify(Self.record(mode: S_IFREG | 0o755, uid: 0), currentUser: 501)
    }

    @Test("a directory is refused")
    func directoryRefused() {
        #expect(throws: ExecutableTrustPolicy.Violation.notRegularFile) {
            try ExecutableTrustPolicy.verify(URL(fileURLWithPath: "/usr/bin"))
        }
    }

    @Test("the check follows a symlink to its target")
    func followsSymlink() throws {
        let target = try Self.makeScratchScript(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let link = target.deletingLastPathComponent().appendingPathComponent("shim")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: ExecutableTrustPolicy.Violation.writableByOthers(mode: 0o777)) {
            try ExecutableTrustPolicy.verify(link)
        }
    }

    @Test("a missing path is left for the spawn to report")
    func missingPathIsNotAViolation() throws {
        try ExecutableTrustPolicy.verify(URL(fileURLWithPath: "/var/empty/gargantua-no-such-tool"))
    }

    @Test("DefaultProcessRunner refuses a world-writable executable before spawning it")
    func runnerRefusesWorldWritable() throws {
        let url = try Self.makeScratchScript(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: ProcessRunnerError.untrustedExecutable(
            path: url.path,
            reason: "its mode 777 lets other users write to it"
        )) {
            try DefaultProcessRunner().run(executable: url, arguments: [])
        }
    }
}
