import Testing
@testable import GargantuaCore

@Suite("DashboardRoadmapPlanner")
@MainActor
struct DashboardRoadmapPlannerTests {
    @Test("A failed triage reads as failed, not as a clean result")
    func failedTriageIsNotClear() {
        let planner = DashboardRoadmapPlanner(
            alerts: [],
            scanProgress: ScanProgress(),
            hasRunTriageScan: true,
            triageIsStale: false,
            triageAgeLabel: "",
            diskUsage: 0.5,
            freeDiskGB: 100,
            triageFailure: "rules directory missing"
        )

        #expect(planner.statusPill == "triage failed")
        #expect(planner.headline.contains("didn't finish"))
        #expect(planner.steps.first?.id == "triage")
    }
}
