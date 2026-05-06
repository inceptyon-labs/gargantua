import Foundation

/// Builds `RemnantItem`s out of `PackageReceiptCandidate`s, applying the
/// Trust Layer's bounded-evidence rules to each candidate before it can
/// reach the uninstall plan.
///
/// **Receipts are evidence, not permission.** This builder enforces that
/// invariant by:
///
/// 1. Dropping non-existent paths silently (stale receipts referencing
///    files an upgrade replaced or moved).
/// 2. Dropping paths that match a `ProtectedRootPolicy` entry — those are
///    *roots*, not items, and a BOM that lists them is a misclassification
///    inside the receipt, not permission to delete a directory containing
///    arbitrary user state.
/// 3. Upgrading shared-system paths to `.protected_` (e.g.
///    `/Library/LaunchDaemons/`, `/Library/Frameworks/`,
///    `/Library/PrivilegedHelperTools/`) — owned by *some* package per the
///    BOM, but not safely actioned without an explicit user override.
/// 4. Defaulting everything else to `.review` — BOM-derived candidates are
///    never `.safe`. The user must look before they leap.
///
/// The resulting `RemnantItem`s carry a `pkgutil-bom` tag and an explanation
/// like "Owned by package com.docker.docker (v4.30.0) installed
/// 2025-12-04." so downstream UI and audit consumers can show provenance.
public struct ReceiptRemnantBuilder: Sendable {
    /// Tag stamped on every receipt-derived `RemnantItem` so consumers can
    /// filter for BOM-evidence rows.
    public static let receiptTag = "pkgutil-bom"

    /// Path prefixes that escalate a receipt finding from `.review` to
    /// `.protected_`. These are shared-system locations where ownership
    /// claimed by a BOM is not enough to act safely.
    public static let protectedSharedPathPrefixes: [String] = [
        "/Library/LaunchDaemons/",
        "/Library/Frameworks/",
        "/Library/PrivilegedHelperTools/",
        "/Library/Extensions/",
        "/System/",
    ]

    private let protectedRoots: ProtectedRootPolicy
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        protectedRoots: ProtectedRootPolicy = ProtectedRootPolicy.loadDefault(),
        fileManager: FileManager = .default
    ) {
        self.protectedRoots = protectedRoots
        self.fileManager = fileManager
    }

    /// Convert a list of receipt candidates into `RemnantItem`s for an app.
    ///
    /// `seenPaths` is consulted (and updated) so a path already produced by
    /// a YAML remnant rule is not duplicated as a BOM finding.
    public func build(
        from candidates: [PackageReceiptCandidate],
        for app: AppInfo,
        seenPaths: inout Set<String>
    ) -> [RemnantItem] {
        var items: [RemnantItem] = []
        var counter = 0
        var seenForReceipts: Set<String> = []

        for candidate in candidates {
            guard !seenPaths.contains(candidate.path) else { continue }
            guard seenForReceipts.insert(candidate.path).inserted else { continue }
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if isProtectedRoot(candidate.path) { continue }

            guard let metadata = metadata(at: candidate.path), metadata.size > 0 else {
                continue
            }

            let safety = safetyLevel(for: candidate.path)
            let confidence = confidence(for: safety)
            let explanation = explanation(for: candidate, safety: safety)

            let item = RemnantItem(
                id: "pkgutil-bom-\(candidate.pkgID)-\(counter)",
                appBundleID: app.bundleID,
                category: .other,
                path: candidate.path,
                size: metadata.size,
                safety: safety,
                confidence: confidence,
                explanation: explanation,
                source: SourceAttribution(
                    name: app.name,
                    bundleID: app.bundleID,
                    verifySignature: false
                ),
                ruleID: "pkgutil-bom:\(candidate.pkgID)",
                lastAccessed: metadata.lastAccessed,
                regenerates: false,
                tags: [Self.receiptTag]
            )
            items.append(item)
            seenPaths.insert(candidate.path)
            counter += 1
        }

        return items
    }

    // MARK: - Internal

    private func isProtectedRoot(_ path: String) -> Bool {
        protectedRoots.protectionReason(for: URL(fileURLWithPath: path)) != nil
    }

    private func safetyLevel(for path: String) -> SafetyLevel {
        if Self.protectedSharedPathPrefixes.contains(where: path.hasPrefix) {
            return .protected_
        }
        return .review
    }

    private func confidence(for safety: SafetyLevel) -> Int {
        // Receipt evidence is reliable as ownership signal but not as a
        // safe-to-delete signal. Cap confidence so the Trust Layer keeps the
        // user in the loop even on mid-confidence rows.
        switch safety {
        case .protected_: 95
        case .review: 75
        case .safe: 60
        }
    }

    private func explanation(
        for candidate: PackageReceiptCandidate,
        safety: SafetyLevel
    ) -> String {
        let version = candidate.pkgVersion.map { " (v\($0))" } ?? ""
        let installed = candidate.installDate.map { " installed \(Self.dateFormatter.string(from: $0))" } ?? ""
        let provenance = "Owned by package \(candidate.pkgID)\(version)\(installed)."

        switch safety {
        case .protected_:
            return "\(provenance) Shared system path — review carefully before removal."
        case .review:
            return "\(provenance) Receipt evidence — review before removal."
        case .safe:
            return provenance
        }
    }

    private func metadata(at path: String) -> (size: Int64, lastAccessed: Date?)? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
        ])

        let size: Int64
        if values?.isDirectory == true {
            size = DirectorySizeScanner.directorySize(at: path).totalSize
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        return (size, values?.contentAccessDate ?? values?.contentModificationDate)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
