import Foundation
import Testing
@testable import GargantuaCore

@Suite("SmartUninstallerViewModel — execution")
@MainActor
struct SmartUninstallerExecutionTests {
    @Test("execute() success transitions to summary with pruned plan")
    func executeSuccess() async {
        let app = makeApp()
        let bundle = makeRemnant(id: "bundle", app: app, category: .other, safety: .review)
        let a = makeRemnant(id: "a", app: app, safety: .safe)
        let b = makeRemnant(id: "b", app: app, safety: .safe)
        let plan = makePlan(app: app, bundle: bundle, remnants: [a, b])

        let executor = StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: executor
        )
        await vm.selectApp(app)
        vm.toggleSelection(a)
        #expect(vm.selectedIDs == ["b"])

        await vm.execute()

        #expect(isPhase(vm.phase, "summary"))
        #expect(executor.planSeen?.allItems.map(\.id) == ["b"])
        #expect(executor.optionsSeen?.confirmationMethod == .singleButton)
        #expect(executor.optionsSeen?.includeProtectedItems == false)
    }

    @Test("execute() with protected item sets fullModal tier and includeProtectedItems")
    func executeProtectedTier() async {
        let app = makeApp()
        let prot = makeRemnant(id: "prot1", app: app, safety: .protected_)
        let plan = makePlan(app: app, remnants: [prot])
        let executor = StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: executor,
            authorizationProvider: { .authorizedForTesting }
        )
        await vm.selectApp(app)
        vm.setIncludeProtected(true)
        vm.toggleSelection(prot)

        await vm.execute()

        #expect(isPhase(vm.phase, "summary"))
        #expect(executor.optionsSeen?.confirmationMethod == .fullModal)
        #expect(executor.optionsSeen?.includeProtectedItems == true)
        #expect(executor.optionsSeen?.authorization?.isAuthorized == true)
    }

    @Test("execute() surfaces executor errors as failed phase")
    func executeFailure() async {
        let app = makeApp()
        let a = makeRemnant(id: "a", app: app, safety: .safe)
        let plan = makePlan(app: app, remnants: [a])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .failure(UninstallExecutionError.authorizationRequired))
        )
        await vm.selectApp(app)

        await vm.execute()

        guard case .failed(let message) = vm.phase else {
            Issue.record("Expected .failed phase, got \(vm.phase)")
            return
        }
        #expect(message.contains("authorization") || message.contains("Admin"))
    }

    @Test("execute() always passes cleanupMethod=.trash, ignoring prior state")
    func executeForcesTrash() async {
        let app = makeApp()
        let a = makeRemnant(id: "a", app: app, safety: .safe)
        let plan = makePlan(app: app, remnants: [a])
        let executor = StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: executor
        )
        await vm.selectApp(app)

        await vm.execute()

        #expect(executor.optionsSeen?.cleanupMethod == .trash)
    }

    @Test("execute() is swallowed outside .reviewingPlan phase")
    func executeReentrancyGuard() async {
        let app = makeApp()
        let a = makeRemnant(id: "a", app: app, safety: .safe)
        let plan = makePlan(app: app, remnants: [a])
        let executor = StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: executor
        )
        await vm.selectApp(app)
        await vm.execute()
        #expect(isPhase(vm.phase, "summary"))

        // Second invocation while in .summary should be a no-op — no new
        // executor call, no phase change.
        let planSeenAfterFirst = executor.planSeen
        await vm.execute()
        #expect(isPhase(vm.phase, "summary"))
        #expect(executor.planSeen?.id == planSeenAfterFirst?.id)
    }

    @Test("reset() returns to pickingApp and clears selection")
    func resetClears() async {
        let app = makeApp()
        let a = makeRemnant(id: "a", app: app, safety: .safe)
        let plan = makePlan(app: app, remnants: [a])
        let vm = SmartUninstallerViewModel(
            appScanner: StubAppScanner(apps: [app]),
            planner: StubPlanner(build: { _, _ in plan }),
            executor: StubExecutor(result: .success(makeExecutionResult(plan: plan)))
        )
        await vm.selectApp(app)
        vm.setIncludeProtected(true)
        #expect(vm.selectedIDs.isEmpty == false)

        vm.reset()
        #expect(isPhase(vm.phase, "pickingApp"))
        #expect(vm.selectedIDs.isEmpty)
        #expect(vm.includeProtected == false)
    }
}
