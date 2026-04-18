import Foundation
import Testing
@testable import GargantuaCore

// MARK: - App picker tests

@Suite("SmartUninstallerViewModel — app picker")
@MainActor
struct SmartUninstallerAppPickerTests {
    @Test("loadApps() populates the picker and advances phase")
    func loadAppsAdvances() async {
        let apps = [makeApp(bundleID: "a", name: "Alpha"), makeApp(bundleID: "b", name: "Beta")]
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: apps),
            planner: StubPlanner(build: { app, _ in makePlan(app: app) }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: makePlan(app: apps[0]))))
        )

        await vm.loadApps()

        #expect(vm.apps.count == 2)
        #expect(isPhase(vm.phase, "pickingApp"))
    }

    @Test("query filter matches name, displayName, and bundleID")
    func queryFilter() async {
        let alpha = AppInfo(
            bundleID: "com.acme.alpha",
            name: "Alpha",
            displayName: "Alpha Pro",
            bundlePath: "/Applications/Alpha.app"
        )
        let beta = AppInfo(bundleID: "com.example.beta", name: "Beta", bundlePath: "/Applications/Beta.app")
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [alpha, beta]),
            planner: StubPlanner(build: { app, _ in makePlan(app: app) }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: makePlan(app: alpha))))
        )
        await vm.loadApps()

        vm.query = "pro"
        #expect(vm.visibleApps.map(\.bundleID) == ["com.acme.alpha"])

        vm.query = "example"
        #expect(vm.visibleApps.map(\.bundleID) == ["com.example.beta"])
    }

    @Test("system app filter hides system apps unless toggled")
    func systemAppFilter() async {
        let user = makeApp(bundleID: "user", name: "User", isSystemApp: false)
        let system = makeApp(bundleID: "system", name: "System", isSystemApp: true)
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [user, system]),
            planner: StubPlanner(build: { app, _ in makePlan(app: app) }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: makePlan(app: user))))
        )
        await vm.loadApps()

        #expect(vm.visibleApps.map(\.bundleID) == ["user"])
        vm.showSystemApps = true
        #expect(Set(vm.visibleApps.map(\.bundleID)) == ["user", "system"])
    }

    @Test("sort=size orders largest first")
    func sortBySize() async {
        let small = makeApp(bundleID: "small", name: "Small", size: 1_000)
        let big = makeApp(bundleID: "big", name: "Big", size: 1_000_000_000)
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [small, big]),
            planner: StubPlanner(build: { app, _ in makePlan(app: app) }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: makePlan(app: small))))
        )
        await vm.loadApps()

        vm.sort = .size
        #expect(vm.visibleApps.map(\.bundleID) == ["big", "small"])
    }
}

// MARK: - Plan review tests

@Suite("SmartUninstallerViewModel — plan review")
@MainActor
struct SmartUninstallerPlanReviewTests {
    @Test("selectApp() pre-selects safe items, leaves review/protected unselected")
    func selectAppPreselection() async {
        let app = makeApp()
        let safe = makeRemnant(id: "safe1", app: app, safety: .safe)
        let review = makeRemnant(id: "rev1", app: app, safety: .review)
        let prot = makeRemnant(id: "prot1", app: app, safety: .protected_)
        let plan = makePlan(app: app, remnants: [safe, review, prot])

        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )

        await vm.selectApp(app)

        #expect(vm.selectedIDs == ["safe1"])
        #expect(isPhase(vm.phase, "reviewingPlan"))
        #expect(vm.includeProtected == false)
    }

    @Test("toggleSelection ignores protected items until unlocked")
    func protectedGating() async {
        let app = makeApp()
        let prot = makeRemnant(id: "prot1", app: app, safety: .protected_)
        let plan = makePlan(app: app, remnants: [prot])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )
        await vm.selectApp(app)

        vm.toggleSelection(prot)
        #expect(vm.selectedIDs.contains("prot1") == false)

        vm.setIncludeProtected(true)
        vm.toggleSelection(prot)
        #expect(vm.selectedIDs.contains("prot1"))
    }

    @Test("setIncludeProtected(false) deselects any protected items already in the set")
    func deselectProtectedOnLock() async {
        let app = makeApp()
        let prot = makeRemnant(id: "prot1", app: app, safety: .protected_)
        let safe = makeRemnant(id: "safe1", app: app, safety: .safe)
        let plan = makePlan(app: app, remnants: [safe, prot])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )
        await vm.selectApp(app)
        vm.setIncludeProtected(true)
        vm.toggleSelection(prot)
        #expect(vm.selectedIDs == ["safe1", "prot1"])

        vm.setIncludeProtected(false)
        #expect(vm.selectedIDs == ["safe1"])
    }

    @Test("canProceed is false when protected items selected without unlock")
    func canProceedBlockedByProtected() async {
        let app = makeApp()
        let prot = makeRemnant(id: "prot1", app: app, safety: .protected_)
        let plan = makePlan(app: app, remnants: [prot])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )
        await vm.selectApp(app)
        vm.setIncludeProtected(true)
        vm.toggleSelection(prot)
        #expect(vm.canProceed)

        vm.setIncludeProtected(false)
        #expect(vm.canProceed == false)
    }

    @Test("selectAll / deselectAll respect protected lock")
    func bulkSelectionRespectsLock() async {
        let app = makeApp()
        let a = makeRemnant(id: "a", app: app, safety: .safe)
        let b = makeRemnant(id: "b", app: app, safety: .review)
        let c = makeRemnant(id: "c", app: app, safety: .protected_)
        let plan = makePlan(app: app, remnants: [a, b, c])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )
        await vm.selectApp(app)
        vm.deselectAll(in: [a, b, c])
        #expect(vm.selectedIDs.isEmpty)

        vm.selectAll(in: [a, b, c])
        #expect(vm.selectedIDs == ["a", "b"])

        vm.setIncludeProtected(true)
        vm.selectAll(in: [a, b, c])
        #expect(vm.selectedIDs == ["a", "b", "c"])
    }

    @Test("selectedTotalBytes sums only selected items")
    func selectedTotal() async {
        let app = makeApp()
        let a = makeRemnant(id: "a", app: app, size: 1_000_000)
        let b = makeRemnant(id: "b", app: app, size: 5_000_000, safety: .review)
        let plan = makePlan(app: app, remnants: [a, b])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )
        await vm.selectApp(app)
        #expect(vm.selectedTotalBytes == 1_000_000)
        vm.toggleSelection(b)
        #expect(vm.selectedTotalBytes == 6_000_000)
    }
}
