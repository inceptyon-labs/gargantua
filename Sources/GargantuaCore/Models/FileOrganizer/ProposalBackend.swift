import Foundation

/// Which engine generated a given `OrganizationProposal`. Recorded on the
/// proposal so the UI can label the source ("Suggested by Cloud AI" vs.
/// "Suggested by on-device rules") and so usage telemetry stays accurate.
public enum ProposalBackend: String, Sendable, Codable, Equatable, Hashable {
    case cloud
    case local
}
