import Foundation

extension SmartUninstallerViewModel {
    // MARK: - Batch flow

    /// Scan every app the user has checked, build their uninstall plans, and
    /// surface them for confirmation. The view shows a single combined
    /// confirm modal listing items from every plan.
    ///
    /// On scan completion the phase remains `.batchScanning(total, total)`
    /// and `batchPlans` is populated; the view binds to `batchPlans` to
    /// decide whether the confirm modal should appear. This avoids a
    /// dedicated "ready to confirm" phase.
    public func startBatchUninstall() async {
        let bundleIDs = multiSelected
        let appsToScan = apps.filter { bundleIDs.contains($0.bundleID) }
        guard !appsToScan.isEmpty else { return }

        pathStream.clear()
        batchPlans = []
        // Default selection: every actionable item from every plan. Matches
        // single-app behavior where safe items are pre-selected.
        selectedIDs = []
        includeProtected = false
        phase = .batchScanning(completed: 0, total: appsToScan.count)

        let planner = observing(self.planner)
        var plans: [UninstallPlan] = []
        for (idx, app) in appsToScan.enumerated() {
            if Task.isCancelled { return }
            let plan = await Task.detached { planner.plan(for: app, includeAppBundle: true) }.value
            plans.append(plan)
            phase = .batchScanning(completed: idx + 1, total: appsToScan.count)
        }

        guard !Task.isCancelled else { return }
        batchPlans = plans
        // Pre-select every actionable item (safe + review). For batch flow
        // the user has chosen "uninstall N apps" without inspecting the
        // plan — defaulting to safe-only would leave the `.app` bundles
        // (review-classified) unselected and surface a "0 items" modal.
        selectedIDs = Set(
            plans.flatMap(\.actionableItems).map(\.id)
        )
    }

    /// Execute every plan in `batchPlans` sequentially and collect their
    /// results. Mirrors the single-app `execute()` path: trash-only,
    /// per-plan tier scaling, post-execution linger, and apps that succeed
    /// are pruned from the cached picker list.
    public func executeBatch() async {
        let plans = batchPlans
        guard !plans.isEmpty else { return }

        var results: [UninstallExecutionResult] = []
        let total = plans.count
        phase = .batchExecuting(completed: 0, total: total)

        let exec = observing(executor)
        for (idx, plan) in plans.enumerated() {
            if Task.isCancelled { break }
            let selected = plan.allItems.filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty else {
                phase = .batchExecuting(completed: idx + 1, total: total)
                continue
            }
            let pruned = UninstallPlan(
                id: plan.id,
                app: plan.app,
                appBundle: selected.first { $0.id == plan.appBundle?.id },
                remnants: selected.filter { $0.id != plan.appBundle?.id },
                createdAt: plan.createdAt
            )
            let tier = confirmationTier(for: pruned.allItems.map { $0.toScanResult() })
            let options = UninstallExecutionOptions(
                includeProtectedItems: includeProtected,
                confirmationMethod: tier,
                cleanupMethod: .trash,
                authorization: authorizationProvider()
            )
            do {
                let result = try await exec.execute(pruned, options: options)
                pruneUninstalledApps([pruned.app])
                results.append(result)
            } catch {
                // Record a synthetic failed result so the summary still
                // accounts for this plan; aborting the whole batch on one
                // failure would mask any successes already trashed.
                let failed = UninstallExecutionResult(
                    cleanupResult: CleanupResult(
                        itemResults: pruned.allItems.map {
                            CleanupItemResult(
                                item: $0.toScanResult(),
                                succeeded: false,
                                error: error.localizedDescription
                            )
                        },
                        cleanupMethod: .trash
                    ),
                    dryRun: false,
                    privilegedItems: [],
                    auditWritten: false
                )
                results.append(failed)
            }
            phase = .batchExecuting(completed: idx + 1, total: total)
        }

        await lingerForBatchSpaghettify(results: results)
        // If severed mid-batch, the partial results were already audit-logged
        // by each successful plan's executor; severTether() routed to picker.
        guard !Task.isCancelled else { return }
        phase = .batchSummary(results)
        batchPlans = []
        multiSelected = []
        selectedIDs = []
    }

    private func lingerForBatchSpaghettify(results: [UninstallExecutionResult]) async {
        let succeeded = results.contains { result in
            result.cleanupResult.itemResults.contains(where: \.succeeded)
        }
        guard succeeded, postExecutionLinger > 0 else { return }
        let nanos = UInt64(postExecutionLinger * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    /// Cancel an in-progress batch flow and return to the picker. Safe to
    /// call from the batch confirm modal's Cancel button.
    public func cancelBatch() {
        batchPlans = []
        selectedIDs = []
        includeProtected = false
        phase = .pickingApp
    }

    /// Combined items to display in the batch confirmation modal —
    /// selected `RemnantItem`s from every plan, mapped to `ScanResult`.
    public var batchSelectedScanResults: [ScanResult] {
        batchPlans
            .flatMap(\.allItems)
            .filter { selectedIDs.contains($0.id) }
            .map { $0.toScanResult() }
    }
}
