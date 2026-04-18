import Foundation
@testable import GargantuaCore

// MARK: - Fixtures

func makeApp(
    bundleID: String = "com.example.demo",
    name: String = "Demo",
    isRunning: Bool = false,
    isSystemApp: Bool = false,
    size: Int64? = 100_000_000,
    lastUsed: Date? = nil
) -> AppInfo {
    AppInfo(
        bundleID: bundleID,
        name: name,
        bundlePath: "/Applications/\(name).app",
        lastUsedDate: lastUsed,
        isRunning: isRunning,
        isSystemApp: isSystemApp,
        sizeOnDisk: size
    )
}

func makeRemnant(
    id: String,
    app: AppInfo,
    category: RemnantCategory = .caches,
    path: String? = nil,
    size: Int64 = 1_000_000,
    safety: SafetyLevel = .safe
) -> RemnantItem {
    RemnantItem(
        id: id,
        appBundleID: app.bundleID,
        category: category,
        path: path ?? "/tmp/\(id)",
        size: size,
        safety: safety,
        confidence: 90,
        explanation: "Test remnant",
        source: SourceAttribution(name: app.name, bundleID: app.bundleID),
        ruleID: "test_rule"
    )
}

func makePlan(
    app: AppInfo,
    bundle: RemnantItem? = nil,
    remnants: [RemnantItem] = []
) -> UninstallPlan {
    UninstallPlan(app: app, appBundle: bundle, remnants: remnants)
}

// MARK: - Test doubles

final class StubAppScanner: AppScanning {
    let apps: [AppInfo]
    init(apps: [AppInfo]) { self.apps = apps }
    func scanApps() async -> [AppInfo] { apps }
}

struct StubPlanner: UninstallPlanning {
    let build: @Sendable (AppInfo, Bool) -> UninstallPlan
    func plan(for app: AppInfo, includeAppBundle: Bool) -> UninstallPlan {
        build(app, includeAppBundle)
    }
}

final class StubExecutor: UninstallExecuting, @unchecked Sendable {
    var planSeen: UninstallPlan?
    var optionsSeen: UninstallExecutionOptions?
    var result: Result<UninstallExecutionResult, Error>

    init(result: Result<UninstallExecutionResult, Error>) {
        self.result = result
    }

    @MainActor
    func execute(_ plan: UninstallPlan, options: UninstallExecutionOptions) async throws -> UninstallExecutionResult {
        planSeen = plan
        optionsSeen = options
        return try result.get()
    }
}

func makeExecutionResult(
    plan: UninstallPlan,
    succeeded: Bool = true,
    privileged: [ScanResult] = []
) -> UninstallExecutionResult {
    let items = plan.allItems.map { item in
        CleanupItemResult(item: item.toScanResult(), succeeded: succeeded)
    }
    return UninstallExecutionResult(
        cleanupResult: CleanupResult(itemResults: items, cleanupMethod: .trash),
        dryRun: false,
        privilegedItems: privileged,
        auditWritten: succeeded
    )
}

// MARK: - Phase matcher

func isPhase(_ phase: SmartUninstallerPhase, _ match: String) -> Bool {
    switch (phase, match) {
    case (.idle, "idle"): true
    case (.loadingApps, "loadingApps"): true
    case (.pickingApp, "pickingApp"): true
    case (.scanning, "scanning"): true
    case (.reviewingPlan, "reviewingPlan"): true
    case (.executing, "executing"): true
    case (.summary, "summary"): true
    case (.failed, "failed"): true
    default: false
    }
}
