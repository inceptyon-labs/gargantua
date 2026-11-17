import CryptoKit
import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseVerifier: change of signer")
struct AppReleaseVerifierSignerTests {
    private typealias Fixtures = AppReleaseInstallFixtures
    private typealias Failure = AppReleaseVerificationFailure

    private static let oldTeam = "TEAM123456"
    private static let newTeam = "NEWTEAM123"
    private static let change = AppReleaseSignerChange(fromTeamID: oldTeam, toTeamID: newTeam)

    private struct RejectingGatekeeper: AppReleaseGatekeeperAssessing {
        func assess(bundleURL _: URL) -> AppReleaseGatekeeperVerdict {
            AppReleaseGatekeeperVerdict(accepted: false, source: nil, detail: "rejected")
        }
    }

    /// A signer reporting a valid Developer ID signature by `newTeam`.
    private func newSigner(certified: Set<String> = [newTeam]) -> StubCodeSigner {
        StubCodeSigner(
            report: AppReleaseSignatureReport(isValid: true, teamID: Self.newTeam, isDeveloperID: true),
            certifiedTeams: certified
        )
    }

    private func approvals(_ change: AppReleaseSignerChange) -> AppReleaseSignerPolicy {
        AppReleaseSignerPolicy(approvals: { [Fixtures.bundleID: [change]] })
    }

    /// Zips a 2.0 `Foo.app` and verifies it as an update of the installed 1.0.
    private func verify(
        signer: StubCodeSigner,
        policy: AppReleaseSignerPolicy = AppReleaseSignerPolicy(),
        gatekeeper: any AppReleaseGatekeeperAssessing = AcceptingGatekeeper(),
        candidate: (Data) throws -> AppReleaseCandidate = { _ in Fixtures.candidate() },
        updateKey: String? = nil
    ) throws -> AppReleaseStagedBundle {
        let directory = try Fixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source/Foo.app")
        try Fixtures.writeBundle(at: source, short: "2.0", build: "200")
        let payload = directory.appendingPathComponent("payload")
        let output = try DefaultProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", source.path, payload.path]
        )
        try #require(output.exitCode == 0)
        let work = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let app = Fixtures.installedApp(at: URL(fileURLWithPath: "/Applications/Foo.app"), sparklePublicEDKey: updateKey)
        return try AppReleaseVerifier(signer: signer, gatekeeper: gatekeeper, signerPolicy: policy).verify(
            payload: payload,
            app: app,
            candidate: candidate(Data(contentsOf: payload)),
            strategy: .inPlace,
            workDirectory: work
        )
    }

    @Test("another team's update that nothing vouches for is offered for approval, and only when it would install")
    func unvouchedChangeIsOffered() throws {
        #expect(throws: Failure.signerChanged(Self.change)) { try verify(signer: newSigner()) }
        // Approval of some other hand-over doesn't cover this one.
        let other = AppReleaseSignerChange(fromTeamID: "OTHERTEAM1", toTeamID: Self.newTeam)
        #expect(throws: Failure.signerChanged(Self.change)) { try verify(signer: newSigner(), policy: approvals(other)) }
        // A certificate Apple didn't issue to the new team, or a Gatekeeper
        // rejection, is a refusal with nothing to approve.
        #expect(throws: Failure.teamCertificateMismatch(Self.newTeam)) {
            try verify(signer: newSigner(certified: []), policy: approvals(Self.change))
        }
        #expect(throws: Failure.gatekeeperRejected("rejected")) {
            try verify(signer: newSigner(), gatekeeper: RejectingGatekeeper())
        }
    }

    @Test("the change passes when the user approved it or the catalog lists it")
    func approvedOrListedChangePasses() throws {
        let approved = try verify(signer: newSigner(), policy: approvals(Self.change))
        #expect(approved.signerChange == AppReleaseAcceptedSignerChange(change: Self.change, basis: .approved))
        #expect(approved.signerChange?.warning == nil)

        let succession = AppReleaseTeamSuccession(
            bundleID: Fixtures.bundleID, name: "Foo", fromTeamID: Self.oldTeam, toTeamID: Self.newTeam, explanation: "Sold."
        )
        let catalog = AppReleaseCatalog(entries: [], successions: [succession])
        let listed = try verify(signer: newSigner(), policy: AppReleaseSignerPolicy(catalog: catalog))
        #expect(listed.signerChange?.basis == .catalog)
        #expect(listed.signerChange?.warning != nil)

        // The installed team's own update carries no change at all.
        #expect(try verify(signer: StubCodeSigner()).signerChange == nil)
    }

    @Test("a download signed with the installed copy's update key vouches for a new signer")
    func updateKeyVouches() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let staged = try verify(
            signer: newSigner(),
            candidate: { Fixtures.candidate(edSignature: try key.signature(for: $0).base64EncodedString()) },
            updateKey: publicKey
        )
        #expect(staged.signerChange?.basis == .updateKey)
        #expect(staged.signerChange?.auditNote == "signer TEAM123456 → NEWTEAM123, vouched for by the installed copy's update key")

        // No key on the installed copy means no signature was checked.
        #expect(throws: Failure.signerChanged(Self.change)) {
            try verify(signer: newSigner(), candidate: { _ in Fixtures.candidate(isSparkleFeed: false) })
        }
    }

    @Test("a catalog pin on another team is refused even with the user's approval")
    func pinnedTeamOverridesApproval() throws {
        #expect(throws: Failure.pinnedTeamIDMismatch(expected: "PINNEDTEAM", actual: Self.newTeam)) {
            try verify(
                signer: newSigner(certified: [Self.newTeam, "PINNEDTEAM"]),
                policy: approvals(Self.change),
                candidate: { _ in Fixtures.candidate(source: .catalog, pinnedTeamID: "PINNEDTEAM") }
            )
        }
    }

    @Test("approvals survive a round trip, names are display only, and blobs stored before the field still decode")
    func approvalsPersist() throws {
        var preferences = AppReleasePreferences()
        let named = AppReleaseSignerChange(fromTeamID: Self.oldTeam, fromName: "Old Dev", toTeamID: Self.newTeam, toName: "New Co")
        preferences.approve(named, for: Fixtures.bundleID)
        preferences.approve(Self.change, for: Fixtures.bundleID)
        #expect(preferences.approvedSigners[Fixtures.bundleID] == [named])
        #expect(named.toLabel == "New Co (NEWTEAM123)")
        #expect(Self.change.toLabel == "NEWTEAM123")

        let decoded = try JSONDecoder().decode(AppReleasePreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
        let legacy = try JSONDecoder().decode(AppReleasePreferences.self, from: Data(#"{"autoCheckEnabled":true}"#.utf8))
        #expect(legacy.approvedSigners.isEmpty)

        #expect(StrictAppReleaseCodeSigner.displayName(fromCertificateSummary: "Developer ID Application: MuseScore (6EPAF2X3PR)")
            == "MuseScore")
        #expect(StrictAppReleaseCodeSigner.displayName(fromCertificateSummary: "Apple Development") == "Apple Development")
    }
}
