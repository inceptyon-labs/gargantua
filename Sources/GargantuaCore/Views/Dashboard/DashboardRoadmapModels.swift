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
}
