import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseVerifier encrypted disk images")
struct AppReleaseVerifierEncryptedImageTests {
    private typealias Fixtures = AppReleaseInstallFixtures
    private typealias Failure = AppReleaseVerificationFailure

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = try Fixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeFile(_ bytes: [UInt8], in directory: URL, named name: String = "payload") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private var someApp: InstalledApp {
        Fixtures.installedApp(at: URL(fileURLWithPath: "/Applications/Foo.app"))
    }

    /// Answers an `attach` that carries `-stdinpass` with `output`; anything else reports a prompt-wait.
    private struct HdiutilStub: ProcessRunner {
        let output: ProcessOutput
        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            if arguments.first == "attach", !arguments.contains("-stdinpass") {
                return ProcessOutput(stdout: "", stderr: "attach without -stdinpass", exitCode: 1)
            }
            return output
        }
    }

    private func verifyDiskImage(failingWith output: ProcessOutput) throws -> Failure? {
        let stub = HdiutilStub(output: output)
        var failure: Failure?
        try withTemporaryDirectory { directory in
            let dmg = try writeFile(
                Array(repeating: 0, count: 2048) + Array("koly".utf8) + Array(repeating: 0, count: 508),
                in: directory
            )
            let work = directory.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            do {
                _ = try AppReleaseVerifier(signer: StubCodeSigner(), gatekeeper: AcceptingGatekeeper(), runner: stub)
                    .verify(payload: dmg, app: someApp, candidate: Fixtures.candidate(downloadURL: "https://example.com/Foo.dmg"),
                            strategy: .inPlace, workDirectory: work)
            } catch let error as Failure { failure = error }
        }
        return failure
    }

    @Test("an encrypted disk image fails with its own message, and attach never waits on stdin")
    func encryptedDiskImage() throws {
        let failure = try verifyDiskImage(failingWith: ProcessOutput(
            stdout: "", stderr: "hdiutil: attach failed - Authentication error", exitCode: 1
        ))
        #expect(failure == .encryptedDiskImage)
    }

    @Test("a license-agreement refusal is still reported as one")
    func licenseRefusalUnchanged() throws {
        let failure = try verifyDiskImage(failingWith: ProcessOutput(
            stdout: "", stderr: "hdiutil: attach canceled", exitCode: 1
        ))
        #expect(failure == .licenseAgreementRequired)
    }

    @Test("a real AES-encrypted disk image is refused at once, not after the attach timeout")
    func realEncryptedDiskImage() throws {
        try withTemporaryDirectory { directory in
            let dmg = directory.appendingPathComponent("Foo.dmg")
            let create = Process()
            create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            create.arguments = [
                "create", "-size", "2m", "-fs", "HFS+", "-volname", "Foo",
                "-encryption", "AES-128", "-stdinpass", dmg.path,
            ]
            let input = Pipe()
            create.standardInput = input
            create.standardOutput = FileHandle.nullDevice
            create.standardError = FileHandle.nullDevice
            guard (try? create.run()) != nil else { return }
            input.fileHandleForWriting.write(Data("secret".utf8))
            try? input.fileHandleForWriting.close()
            create.waitUntilExit()
            guard create.terminationStatus == 0, FileManager.default.fileExists(atPath: dmg.path) else { return }

            let work = directory.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let started = Date()
            #expect(throws: Failure.encryptedDiskImage) {
                try AppReleaseVerifier(signer: StubCodeSigner(), gatekeeper: AcceptingGatekeeper()).verify(
                    payload: dmg, app: someApp,
                    candidate: Fixtures.candidate(downloadURL: "https://example.com/Foo.dmg"),
                    strategy: .inPlace, workDirectory: work
                )
            }
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }
}
