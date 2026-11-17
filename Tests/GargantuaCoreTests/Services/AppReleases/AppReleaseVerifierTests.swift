import CryptoKit
import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseVerifier")
struct AppReleaseVerifierTests {
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

    // MARK: - Team ID

    @Test("a new bundle signed by another team is refused")
    func teamIDMismatch() {
        #expect(throws: Failure.teamIDMismatch(expected: "TEAM123456", actual: "OTHERTEAM1")) {
            try AppReleaseVerifier.checkTeamID("OTHERTEAM1", app: someApp, candidate: Fixtures.candidate())
        }
    }

    @Test("a Team ID is spliced into a requirement only when it is ten uppercase letters and digits")
    func teamRequirementText() {
        #expect(StrictAppReleaseCodeSigner.teamRequirement(for: "ABCDE12345")
            == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        for malformed in ["abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE\" or 1", "ABCDE1234É", ""] {
            #expect(StrictAppReleaseCodeSigner.teamRequirement(for: malformed) == nil)
            #expect(StrictAppReleaseCodeSigner.combinedRequirement(teams: ["ABCDE12345", malformed]) == nil)
        }
        #expect(StrictAppReleaseCodeSigner.combinedRequirement(teams: ["ABCDE12345"])
            == StrictAppReleaseCodeSigner.developerIDRequirement + " and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    /// Zips a 2.0 `Foo.app` the way a vendor would ship it.
    private func zippedUpdate(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try Fixtures.writeBundle(at: source.appendingPathComponent("Foo.app"), short: "2.0", build: "200")
        let payload = directory.appendingPathComponent("payload")
        let output = try DefaultProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [
                "-c", "-k", "--norsrc", "--noextattr", "--keepParent",
                source.appendingPathComponent("Foo.app").path, payload.path,
            ]
        )
        try #require(output.exitCode == 0)
        return payload
    }

    private func verify(_ payload: URL, signer: StubCodeSigner, in directory: URL) throws -> AppReleaseStagedBundle {
        let work = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try AppReleaseVerifier(signer: signer, gatekeeper: AcceptingGatekeeper()).verify(
            payload: payload,
            app: someApp,
            candidate: Fixtures.candidate(),
            strategy: .inPlace,
            workDirectory: work
        )
    }

    @Test("a signature naming the team in its Team ID field but not in an Apple-issued certificate is refused")
    func teamCertificateMismatch() throws {
        try withTemporaryDirectory { directory in
            let payload = try zippedUpdate(in: directory)
            #expect(throws: Failure.teamCertificateMismatch("TEAM123456")) {
                try verify(payload, signer: StubCodeSigner(certifiedTeams: []), in: directory)
            }
        }
    }

    @Test("the same update passes when the certificate belongs to the team")
    func teamCertificateMatch() throws {
        try withTemporaryDirectory { directory in
            let payload = try zippedUpdate(in: directory)
            let staged = try verify(payload, signer: StubCodeSigner(), in: directory)
            #expect(staged.version == AppReleaseVersion(short: "2.0", build: "200"))
        }
    }

    @Test("a catalog-pinned team must also be the certificate's team")
    func pinnedTeamCertificateMismatch() throws {
        let candidate = Fixtures.candidate(source: .catalog, pinnedTeamID: "PINNEDTEAM")
        let teams = AppReleaseVerifier.requiredTeams(app: someApp, candidate: candidate)
        #expect(teams == ["TEAM123456", "PINNEDTEAM"])
        let report = StubCodeSigner().assess(bundleURL: URL(fileURLWithPath: "/tmp/Foo.app"), requiredTeams: teams)
        #expect(throws: Failure.teamCertificateMismatch("PINNEDTEAM")) {
            try AppReleaseVerifier.checkTeamCertificate(report)
        }
    }

    @Test("an installed app without a team ID can't be updated in place")
    func installedTeamIDMissing() {
        let app = Fixtures.installedApp(at: URL(fileURLWithPath: "/Applications/Foo.app"), teamID: nil)
        #expect(throws: Failure.installedTeamIDMissing) {
            try AppReleaseVerifier.checkTeamID("TEAM123456", app: app, candidate: Fixtures.candidate())
        }
    }

    @Test("a catalog-pinned team ID must match even when the installed team matches")
    func pinnedTeamIDMismatch() {
        let candidate = Fixtures.candidate(source: .catalog, pinnedTeamID: "PINNEDTEAM")
        #expect(throws: Failure.pinnedTeamIDMismatch(expected: "PINNEDTEAM", actual: "TEAM123456")) {
            try AppReleaseVerifier.checkTeamID("TEAM123456", app: someApp, candidate: candidate)
        }
    }

    // MARK: - EdDSA

    @Test("a payload signed with the installed app's EdDSA key passes")
    func edSignatureValid() throws {
        try withTemporaryDirectory { directory in
            let bytes = Array("update payload".utf8)
            let payload = try writeFile(bytes, in: directory)
            let key = Curve25519.Signing.PrivateKey()
            let signature = try key.signature(for: Data(bytes))
            let app = Fixtures.installedApp(
                at: URL(fileURLWithPath: "/Applications/Foo.app"),
                sparklePublicEDKey: key.publicKey.rawRepresentation.base64EncodedString()
            )
            let candidate = Fixtures.candidate(edSignature: signature.base64EncodedString())

            try AppReleaseVerifier.checkEdSignature(of: payload, app: app, candidate: candidate)
        }
    }

    @Test("a signature over different bytes is refused")
    func edSignatureInvalid() throws {
        try withTemporaryDirectory { directory in
            let payload = try writeFile(Array("update payload".utf8), in: directory)
            let key = Curve25519.Signing.PrivateKey()
            let signature = try key.signature(for: Data("something else".utf8))
            let app = Fixtures.installedApp(
                at: URL(fileURLWithPath: "/Applications/Foo.app"),
                sparklePublicEDKey: key.publicKey.rawRepresentation.base64EncodedString()
            )
            let candidate = Fixtures.candidate(edSignature: signature.base64EncodedString())

            #expect(throws: Failure.signatureInvalid) {
                try AppReleaseVerifier.checkEdSignature(of: payload, app: app, candidate: candidate)
            }
        }
    }

    @Test("an installed key with an unsigned Sparkle item fails as a missing feed signature")
    func edSignatureMissingFromSparkleFeed() throws {
        try withTemporaryDirectory { directory in
            let payload = try writeFile(Array("update payload".utf8), in: directory)
            let app = Fixtures.installedApp(
                at: URL(fileURLWithPath: "/Applications/Foo.app"),
                sparklePublicEDKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            )

            #expect(throws: Failure.feedSignatureMissing) {
                try AppReleaseVerifier.checkEdSignature(of: payload, app: app, candidate: Fixtures.candidate())
            }
        }
    }

    @Test("a catalog entry pointing at a Sparkle feed can't strip the signature either")
    func edSignatureMissingFromCatalogSparkleFeed() throws {
        try withTemporaryDirectory { directory in
            let payload = try writeFile(Array("update payload".utf8), in: directory)
            let app = Fixtures.installedApp(
                at: URL(fileURLWithPath: "/Applications/Foo.app"),
                sparklePublicEDKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            )
            let candidate = Fixtures.candidate(source: .catalog, isSparkleFeed: true)

            #expect(throws: Failure.feedSignatureMissing) {
                try AppReleaseVerifier.checkEdSignature(of: payload, app: app, candidate: candidate)
            }
        }
    }

    // MARK: - Length and checksum

    @Test("a published SHA-256 that doesn't match the download is refused")
    func sha256Mismatch() throws {
        try withTemporaryDirectory { directory in
            let payload = try writeFile(Array("update payload".utf8), in: directory)
            let other = SHA256.hash(data: Data("other bytes".utf8)).map { String(format: "%02x", $0) }.joined()

            #expect(throws: Failure.checksumMismatch) {
                try AppReleaseVerifier.checkSHA256(of: payload, expected: other)
            }
        }
    }

    @Test("a declared length that differs from the download is refused")
    func lengthMismatch() throws {
        try withTemporaryDirectory { directory in
            let payload = try writeFile(Array(repeating: 0x41, count: 10), in: directory)

            #expect(throws: Failure.lengthMismatch(expected: 11, actual: 10)) {
                try AppReleaseVerifier.checkLength(of: payload, expected: 11)
            }
        }
    }

    // MARK: - Version

    @Test("a staged bundle older than the installed app is refused")
    func downgradeRefused() throws {
        try withTemporaryDirectory { directory in
            let bundle = directory.appendingPathComponent("Foo.app", isDirectory: true)
            try Fixtures.writeBundle(at: bundle, short: "1.0", build: "100")
            let app = Fixtures.installedApp(at: URL(fileURLWithPath: "/Applications/Foo.app"), short: "2.0", build: "200")

            #expect(throws: Failure.notNewer(staged: "1.0 (100)", installed: "2.0 (200)")) {
                try AppReleaseVerifier.checkVersion(
                    of: bundle,
                    installed: app,
                    hostOSVersion: ProcessInfo.processInfo.operatingSystemVersion
                )
            }
        }
    }

    // MARK: - Archive entries and payload sniff

    @Test("archive entries that climb out or are absolute are refused; ordinary paths pass")
    func archiveEntryPolicy() throws {
        #expect(throws: Failure.unsafeArchiveEntry("../evil")) {
            try AppReleaseVerifier.validateArchiveEntries(["Foo.app/", "../evil"])
        }
        #expect(throws: Failure.unsafeArchiveEntry("/abs")) {
            try AppReleaseVerifier.validateArchiveEntries(["/abs"])
        }
        try AppReleaseVerifier.validateArchiveEntries(["Foo.app/", "Foo.app/Contents/Info.plist"])
    }

    @Test("an entry under a path another entry stores as a file or link is refused")
    func archiveEntryThroughLink() throws {
        #expect(throws: Failure.unsafeArchiveEntry("x/evil.txt")) {
            try AppReleaseVerifier.validateArchiveEntries(["x", "x/evil.txt"])
        }
        // The same path spelled another way, or in another case, is the same
        // path on APFS.
        #expect(throws: Failure.unsafeArchiveEntry("x/evil.txt")) {
            try AppReleaseVerifier.validateArchiveEntries(["./x", "x/evil.txt"])
        }
        #expect(throws: Failure.unsafeArchiveEntry("x/evil.txt")) {
            try AppReleaseVerifier.validateArchiveEntries(["X", "x/evil.txt"])
        }
        try AppReleaseVerifier.validateArchiveEntries(["Foo.app/", "Foo.app/Contents/Info.plist"])
        try AppReleaseVerifier.validateArchiveEntries(["Foo.app/Contents/MacOS/foo", "Foo.app/Contents/MacOS/foo.dSYM"])
    }
}

extension AppReleaseVerifierTests {

    // MARK: - Disk space

    @Test("unpacking needs four times the payload free, and at least 1 GiB")
    func freeSpaceGuard() throws {
        let gib: Int64 = 1_073_741_824
        try AppReleaseVerifier.checkFreeSpace(available: gib, payloadSize: 100 * 1_048_576)
        try AppReleaseVerifier.checkFreeSpace(available: 8 * gib, payloadSize: 2 * gib)
        #expect(throws: Failure.insufficientDiskSpace(needed: gib, available: gib - 1)) {
            try AppReleaseVerifier.checkFreeSpace(available: gib - 1, payloadSize: 100 * 1_048_576)
        }
        #expect(throws: Failure.insufficientDiskSpace(needed: 8 * gib, available: 8 * gib - 1)) {
            try AppReleaseVerifier.checkFreeSpace(available: 8 * gib - 1, payloadSize: 2 * gib)
        }
        #expect(throws: Failure.insufficientDiskSpace(needed: gib, available: nil)) {
            try AppReleaseVerifier.checkFreeSpace(available: nil, payloadSize: 1)
        }
    }

    @Test("an unpacked tree over 16 GiB is refused")
    func extractedSizeLimit() throws {
        let limit: Int64 = 16 * 1_073_741_824
        try AppReleaseVerifier.checkExtractedSize(limit)
        #expect(throws: Failure.extractedTooLarge(limit: limit)) {
            try AppReleaseVerifier.checkExtractedSize(limit + 1)
        }
    }

    @Test("an extraction that outgrows its budget is killed while it runs")
    func runawayExtractionIsKilled() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // Appends 1 MiB every 20 ms and would run for over 8 s; the budget is 4 MiB.
            let script = "i=0; while [ $i -lt 400 ]; do /usr/bin/head -c 1048576 /dev/zero >> \"$0\"; /bin/sleep 0.02; i=$((i+1)); done"
            let budget: Int64 = 4 * 1_048_576
            let started = Date()
            #expect(throws: Failure.extractedTooLarge(limit: budget)) {
                try AppReleaseVerifier().extract(
                    "/bin/sh", ["-c", script, destination.appendingPathComponent("blob").path],
                    into: destination, budget: budget
                )
            }
            #expect(Date().timeIntervalSince(started) < 6)
        }
    }

    @Test("the extraction budget is the 16 GiB cap, or what leaves 512 MiB free")
    func extractionBudget() {
        #expect(AppReleaseVerifier.extractionBudget(available: 1 << 40) == AppReleaseVerifier.maxExtractedBytes)
        #expect(AppReleaseVerifier.extractionBudget(available: 2 << 30) == (2 << 30) - AppReleaseVerifier.extractionReserveBytes)
        #expect(AppReleaseVerifier.extractionBudget(available: 1024) == 0)
    }

    @Test("zip, gzip and a UDIF trailer are recognized by their bytes")
    func payloadSniffRecognizesKinds() throws {
        try withTemporaryDirectory { directory in
            let zip = try writeFile([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 60), in: directory, named: "a")
            let gzip = try writeFile([0x1F, 0x8B, 0x08, 0x00] + Array(repeating: 0, count: 60), in: directory, named: "b")
            let dmg = try writeFile(
                Array(repeating: 0, count: 2048) + Array("koly".utf8) + Array(repeating: 0, count: 508),
                in: directory,
                named: "c"
            )

            #expect(try AppReleaseVerifier.sniffPayload(zip, declared: .unknown) == .zip)
            #expect(try AppReleaseVerifier.sniffPayload(gzip, declared: .tar) == .tar)
            #expect(try AppReleaseVerifier.sniffPayload(dmg, declared: .dmg) == .dmg)
        }
    }

    @Test("an installer package is refused, and so is a payload that isn't what it claimed")
    func payloadSniffRefusals() throws {
        try withTemporaryDirectory { directory in
            let xar = try writeFile(Array("xar!".utf8) + Array(repeating: 0, count: 60), in: directory, named: "a")
            let zip = try writeFile([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 60), in: directory, named: "b")

            #expect(throws: Failure.installerPackage) {
                try AppReleaseVerifier.sniffPayload(xar, declared: .unknown)
            }
            #expect(throws: Failure.payloadKindMismatch(declared: .dmg, actual: .zip)) {
                try AppReleaseVerifier.sniffPayload(zip, declared: .dmg)
            }
        }
    }

    // MARK: - Locate

    @Test("with two apps unpacked, the one carrying the installed bundle ID is chosen")
    func locatePicksMatchingBundleID() throws {
        try withTemporaryDirectory { directory in
            try Fixtures.writeBundle(
                at: directory.appendingPathComponent("Helper.app"),
                bundleID: "com.example.Helper",
                short: "2.0",
                build: "200"
            )
            try Fixtures.writeBundle(at: directory.appendingPathComponent("Foo.app"), short: "2.0", build: "200")

            let located = try AppReleaseVerifier.locateApp(in: directory, bundleID: Fixtures.bundleID)
            #expect(located.lastPathComponent == "Foo.app")
        }
    }

    @Test("a symlinked .app is never followed")
    func locateIgnoresSymlinkedApp() throws {
        try withTemporaryDirectory { directory in
            let elsewhere = directory.appendingPathComponent("elsewhere/Foo.app", isDirectory: true)
            try Fixtures.writeBundle(at: elsewhere, short: "2.0", build: "200")
            let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: extracted.appendingPathComponent("Foo.app"),
                withDestinationURL: elsewhere
            )

            #expect(throws: Failure.appNotFound) {
                try AppReleaseVerifier.locateApp(in: extracted, bundleID: Fixtures.bundleID)
            }
        }
    }

    @Test("no app with the installed bundle ID fails")
    func locateNoMatch() throws {
        try withTemporaryDirectory { directory in
            try Fixtures.writeBundle(
                at: directory.appendingPathComponent("Other.app"),
                bundleID: "com.example.Other",
                short: "2.0",
                build: "200"
            )

            #expect(throws: Failure.appNotFound) {
                try AppReleaseVerifier.locateApp(in: directory, bundleID: Fixtures.bundleID)
            }
        }
    }

    // MARK: - Tree walk

    @Test("a symlink that points outside the bundle is refused")
    func treeWalkRejectsEscapingSymlink() throws {
        try withTemporaryDirectory { directory in
            let bundle = directory.appendingPathComponent("Foo.app", isDirectory: true)
            try Fixtures.writeBundle(at: bundle, short: "2.0", build: "200")
            let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("etc").path, withDestinationPath: "/etc")

            #expect(throws: Failure.symlinkEscapesBundle("Contents/Resources/etc")) {
                try AppReleaseVerifier.walkBundleTree(bundle)
            }
        }
    }

    @Test("framework-style symlinks inside the bundle are accepted")
    func treeWalkAcceptsInternalSymlinks() throws {
        try withTemporaryDirectory { directory in
            let bundle = directory.appendingPathComponent("Foo.app", isDirectory: true)
            try Fixtures.writeBundle(at: bundle, short: "2.0", build: "200")
            let framework = bundle.appendingPathComponent("Contents/Frameworks/Kit.framework", isDirectory: true)
            let versionA = framework.appendingPathComponent("Versions/A", isDirectory: true)
            try FileManager.default.createDirectory(at: versionA, withIntermediateDirectories: true)
            try Data("binary".utf8).write(to: versionA.appendingPathComponent("Kit"))
            try FileManager.default.createSymbolicLink(
                atPath: framework.appendingPathComponent("Versions/Current").path,
                withDestinationPath: "A"
            )
            try FileManager.default.createSymbolicLink(
                atPath: framework.appendingPathComponent("Kit").path,
                withDestinationPath: "Versions/Current/Kit"
            )

            try AppReleaseVerifier.walkBundleTree(bundle)
        }
    }

    @Test("a chain of links that each look internal but resolve outside is refused")
    func treeWalkRejectsChainedEscape() throws {
        try withTemporaryDirectory { directory in
            let bundle = directory.appendingPathComponent("Foo.app", isDirectory: true)
            try Fixtures.writeBundle(at: bundle, short: "2.0", build: "200")
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            // `up` resolves to the bundle root; `out` reads as `Contents` by
            // text but is the root's parent on disk.
            try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("up").path, withDestinationPath: "..")
            try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("out").path, withDestinationPath: "up/..")

            #expect(throws: Failure.symlinkEscapesBundle("Contents/out")) {
                try AppReleaseVerifier.walkBundleTree(bundle)
            }
        }
    }
}
