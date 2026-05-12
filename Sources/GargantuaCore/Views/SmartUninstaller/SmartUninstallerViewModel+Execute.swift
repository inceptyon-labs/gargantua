import Foundation

extension SmartUninstallerViewModel {
    // MARK: - Single-app execute

    /// Run the uninstall. Surfaces execution errors as a `.failed` phase so
    /// the UI can show the message and offer retry.
    ///
    /// Only runs from `.reviewingPlan`; double-confirms or key-repeat on the
    /// confirm button are swallowed. Cleanup is hard-wired to Trash because
    /// `UninstallExecutor` rejects anything else.
    public func execute() async {
        guard case .reviewingPlan(let plan) = phase, canProceed else { return }
        let selectedItems = plan.allItems.filter { selectedIDs.contains($0.id) }
        let prunedPlan = UninstallPlan(
            id: plan.id,
            app: plan.app,
            appBundle: selectedItems.first { $0.id == plan.appBundle?.id },
            remnants: selectedItems.filter { $0.id != plan.appBundle?.id },
            createdAt: plan.createdAt
        )

        let tier = confirmationTier(for: prunedPlan.allItems.map { $0.toScanResult() })
        let options = UninstallExecutionOptions(
            includeProtectedItems: includeProtected,
            confirmationMethod: tier,
            cleanupMethod: .trash,
            authorization: authorizationProvider()
        )

        phase = .executing(prunedPlan)
        let exec = observing(executor)
        do {
            let result = try await exec.execute(prunedPlan, options: options)
            // Drop the app from the cached picker list when its bundle is
            // gone, so navigating back lands on a fresh list without a full
            // rescan. Idempotent: pruneUninstalledApps stat-checks each path.
            pruneUninstalledApps([prunedPlan.app])
            // Hold the EventHorizonConsole on screen long enough for the
            // spaghettify swallow animation to play. Without this hold, fast
            // uninstalls (small apps, few items) transition straight to the
            // summary card and SwiftUI cancels the per-row .task before its
            // dwell timer fires, so the swallow effect is invisible.
            await lingerForSpaghettify(after: result)
            // If the user severed the tether mid-execute, severTether()
            // already routed to picker/idle and the audit trail records what
            // actually ran. Don't pivot to a summary in that case.
            guard !Task.isCancelled else { return }
            phase = .summary(prunedPlan, result)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Spaghettify visuals last `Spaghettify.dwell + Spaghettify.duration`
    /// (~0.65s); add a small buffer for the per-row `.task` startup. Skip the
    /// linger if no items succeeded — there's nothing to swallow.
    private func lingerForSpaghettify(after result: UninstallExecutionResult) async {
        let succeeded = result.cleanupResult.itemResults.contains(where: \.succeeded)
        guard succeeded, postExecutionLinger > 0 else { return }
        let nanos = UInt64(postExecutionLinger * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
}
