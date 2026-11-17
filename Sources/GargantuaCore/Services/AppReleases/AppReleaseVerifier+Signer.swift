import Foundation

/// What the signer checks found about a staged bundle.
struct AppReleaseSignerCheck {
    let report: AppReleaseSignatureReport
    /// Set when another team than the installed copy's signed the bundle.
    let change: AppReleaseSignerChange?
    /// Why that change is acceptable; nil when nothing vouches for it.
    let basis: AppReleaseSignerBasis?

    var acceptedChange: AppReleaseAcceptedSignerChange? {
        guard let change, let basis else { return nil }
        return AppReleaseAcceptedSignerChange(change: change, basis: basis)
    }

    var unvouchedChange: AppReleaseSignerChange? { basis == nil ? change : nil }
}

extension AppReleaseVerifier {

    // MARK: - Code signature

    func checkCodeSignature(
        _ bundle: URL,
        requiredTeams: [String]
    ) throws(AppReleaseVerificationFailure) -> AppReleaseSignatureReport {
        let report = signer.assess(bundleURL: bundle, requiredTeams: requiredTeams)
        guard report.isValid else { throw .invalidCodeSignature(report.failure ?? "unknown error") }
        guard report.isDeveloperID else { throw .notDeveloperID }
        return report
    }

    // MARK: - Team ID

    /// The signature and Team ID checks. A bundle signed by another team
    /// than the installed copy's is checked against that team's certificate
    /// instead, and reported as a change with whatever vouches for it: the
    /// catalog, the installed copy's update key, or the user's approval.
    func checkSigner(
        of bundle: URL,
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        vouchedByUpdateKey: Bool
    ) throws(AppReleaseVerificationFailure) -> AppReleaseSignerCheck {
        var report = try checkCodeSignature(bundle, requiredTeams: Self.requiredTeams(app: app, candidate: candidate))
        guard let installed = app.teamID?.trimmedNonEmpty, let staged = report.teamID, staged != installed else {
            try Self.checkTeamID(report.teamID, app: app, candidate: candidate)
            return AppReleaseSignerCheck(report: report, change: nil, basis: nil)
        }

        report = try checkCodeSignature(bundle, requiredTeams: Self.requiredTeams(team: staged, candidate: candidate))
        // A catalog pin names the signer outright; nothing overrides it.
        try Self.checkTeamID(staged, app: app, candidate: candidate, successor: staged)
        let change = AppReleaseSignerChange(
            fromTeamID: installed,
            fromName: signer.signerName(ofBundle: app.url),
            toTeamID: staged,
            toName: report.signerName
        )
        let basis = signerPolicy.basis(for: change, bundleID: app.bundleID, vouchedByUpdateKey: vouchedByUpdateKey)
        return AppReleaseSignerCheck(report: report, change: change, basis: basis)
    }

    static func checkTeamID(
        _ stagedTeamID: String?,
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        successor: String? = nil
    ) throws(AppReleaseVerificationFailure) {
        guard let installed = app.teamID?.trimmedNonEmpty else { throw .installedTeamIDMissing }
        guard stagedTeamID == installed || (successor != nil && stagedTeamID == successor) else {
            throw .teamIDMismatch(expected: installed, actual: stagedTeamID)
        }
        if let pinned = candidate.pinnedTeamID, pinned != stagedTeamID {
            throw .pinnedTeamIDMismatch(expected: pinned, actual: stagedTeamID)
        }
    }

    /// The Team ID field alone is just a string in the signature; Apple must
    /// also have issued the leaf certificate to that team, for the installed
    /// app's team and any catalog-pinned one. The signer checks these in the
    /// same pass as the signature.
    static func requiredTeams(app: InstalledApp, candidate: AppReleaseCandidate) -> [String] {
        requiredTeams(team: app.teamID?.trimmedNonEmpty, candidate: candidate)
    }

    static func requiredTeams(team: String?, candidate: AppReleaseCandidate) -> [String] {
        var teams = [team].compactMap { $0 }
        if let pinned = candidate.pinnedTeamID, !teams.contains(pinned) { teams.append(pinned) }
        return teams
    }

    static func checkTeamCertificate(_ report: AppReleaseSignatureReport) throws(AppReleaseVerificationFailure) {
        if let team = report.uncertifiedTeam { throw .teamCertificateMismatch(team) }
    }
}
