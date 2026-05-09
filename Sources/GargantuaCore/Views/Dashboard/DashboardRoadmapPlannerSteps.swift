extension DashboardRoadmapPlanner {
    var steps: [DashboardRoadmapStep] {
        if scanProgress.isScanning {
            return scanningRoadmap
        }

        if !hasRunTriageScan && !scanProgress.isScanning {
            return preTriageRoadmap
        }

        let base = alerts.isEmpty ? noFindingsRoadmap : alertDrivenRoadmap

        if triageIsStale {
            return [staleTriageStep] + bumpedRanks(base)
        }
        return base
    }
}

private extension DashboardRoadmapPlanner {
    var staleTriageStep: DashboardRoadmapStep {
        DashboardRoadmapStep(
            id: "triage-refresh",
            rank: 1,
            title: "Refresh Triage",
            status: "Stale",
            detail: "Last triage finished \(triageAgeLabel). Re-run the lightweight pass so the roadmap reflects what's on disk now.",
            evidence: ["local only", "safe + review items", "no deletion"],
            actionLabel: "Refresh Triage",
            systemImage: "arrow.clockwise",
            action: .scan
        )
    }

    var scanningRoadmap: [DashboardRoadmapStep] {
        [
            DashboardRoadmapStep(
                id: "triage-running",
                rank: 1,
                title: "Triage Scan",
                status: "Scanning",
                detail: scanProgress.currentCategory.map { "Checking \($0) and grouping matches by cleanup tool." }
                    ?? "Checking lightweight local rules and building the ordered tool list.",
                evidence: [
                    "\(Int((scanProgress.fractionCompleted * 100).rounded()))% complete",
                    scanProgress.itemsFound > 0 ? "\(scanProgress.itemsFound) items found" : "collecting evidence",
                ],
                actionLabel: "Scanning",
                systemImage: "hourglass",
                action: .scan
            ),
        ]
    }

    var preTriageRoadmap: [DashboardRoadmapStep] {
        [
            DashboardRoadmapStep(
                id: "triage",
                rank: 1,
                title: "Run Triage Scan",
                status: "Needed",
                detail: "Builds this roadmap from lightweight local cleanup rules before you spend time in deeper tools.",
                evidence: ["local only", "safe + review items", "no deletion"],
                actionLabel: "Run Triage",
                systemImage: "list.bullet.clipboard",
                action: .scan
            ),
            navigationStep(
                id: "deepClean",
                rank: 2,
                title: "Deep Clean",
                status: "Common first pass",
                detail: "Caches, logs, temporary files, trash, and installers. Triage can usually route concrete findings here.",
                evidence: ["caches", "logs", "trash"],
                systemImage: "bubbles.and.sparkles",
                selection: "deepClean"
            ),
            navigationStep(
                id: "devPurge",
                rank: 3,
                title: "Dev Artifact Purge",
                status: "Developer cleanup",
                detail: "Node, Docker, Homebrew, Xcode, and build outputs. This is where developer-disk pressure usually lives.",
                evidence: ["node_modules", "Docker", "build caches"],
                systemImage: "hammer",
                selection: "devPurge"
            ),
            navigationStep(
                id: "smartUninstaller",
                rank: 4,
                title: "Smart Uninstaller",
                status: "Manual app pass",
                detail: "Use when large apps or remnants are the real target. Triage does not decide which apps you want removed.",
                evidence: smartUninstallerEvidence(extra: ["user intent"]),
                systemImage: "trash.slash",
                selection: "smartUninstaller"
            ),
            navigationStep(
                id: "duplicateFinder",
                rank: 5,
                title: "Duplicate Finder",
                status: "Deeper scan",
                detail: "Run after obvious bulk cleanup. Duplicate matching costs more time than triage, so it belongs later.",
                evidence: ["content match", "review required"],
                systemImage: "doc.on.doc",
                selection: "duplicateFinder"
            ),
        ]
    }

    var noFindingsRoadmap: [DashboardRoadmapStep] {
        [
            navigationStep(
                id: "diskExplorer",
                rank: 1,
                title: "Disk Explorer",
                status: diskUsage > 0.75 ? "Inspect pressure" : "Optional",
                detail: "Use this when the numbers still feel wrong. It shows where space is going without relying on cleanup rules.",
                evidence: ["manual inspection", "\(freeDiskGB) GB free"],
                systemImage: "internaldrive",
                selection: "diskExplorer"
            ),
            navigationStep(
                id: "smartUninstaller",
                rank: 2,
                title: "Smart Uninstaller",
                status: "Manual app pass",
                detail: "Look for large apps and remnants that triage intentionally avoids because app removal needs user intent.",
                evidence: smartUninstallerEvidence(extra: ["remnants"]),
                systemImage: "trash.slash",
                selection: "smartUninstaller"
            ),
            navigationStep(
                id: "duplicateFinder",
                rank: 3,
                title: "Duplicate Finder",
                status: "Deeper scan",
                detail: "Check duplicate files after the cheap cleanup pass is clear.",
                evidence: ["content match", "manual review"],
                systemImage: "doc.on.doc",
                selection: "duplicateFinder"
            ),
            navigationStep(
                id: "fileHealth",
                rank: 4,
                title: "File Health",
                status: "Integrity check",
                detail: "Review broken links, risky leftovers, and file-health issues that are not primarily space reclamation.",
                evidence: ["broken links", "risk review"],
                systemImage: "stethoscope",
                selection: "fileHealth"
            ),
        ]
    }

    var alertDrivenRoadmap: [DashboardRoadmapStep] {
        var rank = 1
        var nextSteps: [DashboardRoadmapStep] = []
        let destinations = [AlertDestination.deepClean, .devPurge, .diskExplorer]

        for destination in destinations.compactMap({ destination in
            alertAggregate(for: destination).map { (destination, $0) }
        }).sorted(by: { $0.1.size > $1.1.size }) {
            let (target, aggregate) = destination
            nextSteps.append(alertStep(destination: target, aggregate: aggregate, rank: rank))
            rank += 1
        }

        let followUpCandidates: [DashboardRoadmapStep] = [
            navigationStep(
                id: "devPurge",
                rank: 0,
                title: "Dev Artifact Purge",
                status: "Developer cleanup",
                detail: "Node, Docker, Homebrew, Xcode, and build outputs. Triage on the Light profile does not probe these — open this tool to scan them directly.",
                evidence: ["node_modules", "Docker", "build caches"],
                systemImage: "hammer",
                selection: "devPurge"
            ),
            navigationStep(
                id: "smartUninstaller",
                rank: 0,
                title: "Smart Uninstaller",
                status: "Manual follow-up",
                detail: "Use after reclaimable groups if installed apps or orphaned remnants are the likely source.",
                evidence: smartUninstallerEvidence(extra: ["not triage-owned"]),
                systemImage: "trash.slash",
                selection: "smartUninstaller"
            ),
            navigationStep(
                id: "duplicateFinder",
                rank: 0,
                title: "Duplicate Finder",
                status: "Deeper pass",
                detail: "Run once the obvious cleanup is handled. Duplicate matching is slower and needs explicit review.",
                evidence: ["content match", "review required"],
                systemImage: "doc.on.doc",
                selection: "duplicateFinder"
            ),
            navigationStep(
                id: "diskExplorer",
                rank: 0,
                title: "Disk Explorer",
                status: "Verify space",
                detail: "Use if free space is still tight after the recommended cleanup passes.",
                evidence: ["space map", "\(freeDiskGB) GB free"],
                systemImage: "internaldrive",
                selection: "diskExplorer"
            ),
        ].filter { candidate in
            !nextSteps.contains { $0.id == candidate.id }
        }

        // Apply contiguous ranks after the triage-derived nextSteps so the
        // numbering stays clean even when one of the candidates was already
        // promoted (e.g. Dev Purge surfacing as a triage match).
        for (offset, step) in followUpCandidates.enumerated() {
            nextSteps.append(
                DashboardRoadmapStep(
                    id: step.id,
                    rank: rank + offset,
                    title: step.title,
                    status: step.status,
                    detail: step.detail,
                    evidence: step.evidence,
                    actionLabel: step.actionLabel,
                    systemImage: step.systemImage,
                    action: step.action,
                    reclaimableBytes: step.reclaimableBytes
                )
            )
        }

        return nextSteps
    }

    func bumpedRanks(_ steps: [DashboardRoadmapStep]) -> [DashboardRoadmapStep] {
        steps.enumerated().map { index, step in
            DashboardRoadmapStep(
                id: step.id,
                rank: index + 2,
                title: step.title,
                status: step.status == "Start here" ? "Top reclaim" : step.status,
                detail: step.detail,
                evidence: step.evidence,
                actionLabel: step.actionLabel,
                systemImage: step.systemImage,
                action: step.action,
                reclaimableBytes: step.reclaimableBytes
            )
        }
    }

    func alertAggregate(for destination: AlertDestination) -> DashboardRoadmapAggregate? {
        let matching = alerts.filter { $0.destination == destination }
        guard !matching.isEmpty else { return nil }
        let categories = Array(Set(matching.map(\.categoryLabel))).sorted()
        return DashboardRoadmapAggregate(
            size: matching.reduce(Int64(0)) { $0 + $1.reclaimableSize },
            itemCount: matching.reduce(0) { $0 + $1.itemCount },
            categories: categories
        )
    }

    func alertStep(
        destination: AlertDestination,
        aggregate: DashboardRoadmapAggregate,
        rank: Int
    ) -> DashboardRoadmapStep {
        DashboardRoadmapStep(
            id: destination.rawValue,
            rank: rank,
            title: destinationLabel(destination),
            status: rank == 1 ? "Start here" : "Then check",
            detail: roadmapDetail(for: destination),
            evidence: [
                aggregate.itemCount == 1 ? "1 item" : "\(aggregate.itemCount) items",
                aggregate.categories.prefix(2).joined(separator: ", "),
            ].filter { !$0.isEmpty },
            actionLabel: "Open",
            systemImage: systemImage(for: destination),
            action: .navigate(destination.rawValue),
            reclaimableBytes: aggregate.size
        )
    }

    // swiftlint:disable:next function_parameter_count
    func navigationStep(
        id: String,
        rank: Int,
        title: String,
        status: String,
        detail: String,
        evidence: [String],
        systemImage: String,
        selection: String
    ) -> DashboardRoadmapStep {
        DashboardRoadmapStep(
            id: id,
            rank: rank,
            title: title,
            status: status,
            detail: detail,
            evidence: evidence,
            actionLabel: "Open",
            systemImage: systemImage,
            action: .navigate(selection)
        )
    }

    /// Compose Smart Uninstaller evidence pills with a live app count when
    /// it has loaded. Falls back to a generic "apps" label so the pill never
    /// reads "0 apps" before the dashboard's first metric pass completes.
    func smartUninstallerEvidence(extra: [String]) -> [String] {
        let leading: String
        if installedAppCount > 0 {
            leading = installedAppCount == 1 ? "1 app" : "\(installedAppCount) apps"
        } else {
            leading = "apps"
        }
        return [leading] + extra
    }

    func roadmapDetail(for destination: AlertDestination) -> String {
        switch destination {
        case .deepClean:
            return "Review safe and review-tier cleanup groups: caches, logs, trash, installers, and temporary files."
        case .devPurge:
            return "Clear developer artifacts that can usually be rebuilt: Node dependencies, Docker data, Homebrew cache, and build outputs."
        case .diskExplorer:
            return "Inspect broad disk usage when reclaimable groups point to space pressure rather than one cleanup category."
        }
    }

    func systemImage(for destination: AlertDestination) -> String {
        switch destination {
        case .deepClean: return "bubbles.and.sparkles"
        case .devPurge: return "hammer"
        case .diskExplorer: return "internaldrive"
        }
    }

    func destinationLabel(_ destination: AlertDestination) -> String {
        switch destination {
        case .deepClean: return "Deep Clean"
        case .devPurge: return "Dev Artifact Purge"
        case .diskExplorer: return "Disk Explorer"
        }
    }
}

private struct DashboardRoadmapAggregate {
    let size: Int64
    let itemCount: Int
    let categories: [String]
}
