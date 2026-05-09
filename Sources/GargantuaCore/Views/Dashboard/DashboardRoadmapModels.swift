enum DashboardRoadmapAction: Equatable {
    case scan
    case navigate(String)
}

struct DashboardRoadmapStep: Identifiable {
    let id: String
    let rank: Int
    let title: String
    let status: String
    let detail: String
    let evidence: [String]
    let actionLabel: String
    let systemImage: String
    let action: DashboardRoadmapAction
    /// Reclaimable bytes for this step. `nil` for steps that don't represent a
    /// triage-derived bucket (pre-triage placeholders, "Refresh Triage", etc.)
    /// — those rows render no progress bar.
    let reclaimableBytes: Int64?

    init(
        id: String,
        rank: Int,
        title: String,
        status: String,
        detail: String,
        evidence: [String],
        actionLabel: String,
        systemImage: String,
        action: DashboardRoadmapAction,
        reclaimableBytes: Int64? = nil
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.status = status
        self.detail = detail
        self.evidence = evidence
        self.actionLabel = actionLabel
        self.systemImage = systemImage
        self.action = action
        self.reclaimableBytes = reclaimableBytes
    }
}
