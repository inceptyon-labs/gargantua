import SwiftUI

/// Provenance & Trust block for the rule detail pane.
///
/// Makes legible the things that distinguish Gargantua's rules from an opaque
/// cleaner's definition blob: where the rule comes from, what guards protect
/// you, and what happens to the files after removal. Everything shown is
/// derived from data the rule actually carries — no fabricated authorship.
extension RuleViewerView {
    /// Sync provenance for the bundled rule snapshot, if the sync script has run.
    static let syncManifest = RuleSyncManifest.loadBundled()

    static let upstreamLabel = "inceptyon-labs/gargantua-rules"

    /// Link to the exact synced commit when known, else the repo's rule tree.
    static var upstreamURL: URL {
        if let manifest = syncManifest,
           let url = URL(string: "\(manifest.upstream)/tree/\(manifest.commit)/rules") {
            return url
        }
        return URL(string: "https://github.com/inceptyon-labs/gargantua-rules/tree/main/rules")!
    }

    /// Marketing version baked into the running binary. `swift run` builds have
    /// no Info.plist version, so fall back to a "source build" label.
    static var bundledSnapshotVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return "v\(version)"
        }
        return "source build"
    }

    /// Origin and upstream rows for a rule from the bundled snapshot.
    @ViewBuilder
    private var bundledOrigin: some View {
        provenanceRow(label: "Origin") {
            Text("Bundled snapshot · \(Self.bundledSnapshotVersion)")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)
        }

        provenanceRow(label: "Upstream") {
            Link(destination: Self.upstreamURL) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Text(Self.upstreamLabel)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.accent)
            }
            .buttonStyle(.plain)
            .help("Browse the public rule source-of-truth repository")

            if let manifest = Self.syncManifest {
                Text("synced \(manifest.syncedAt) · rules @ \(manifest.shortCommit)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .textSelection(.enabled)
            }
        }
    }

    func ruleProvenance(_ rule: ScanRule) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("Provenance & Trust")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                if customRuleIDs.contains(rule.id) {
                    provenanceRow(label: "Origin") {
                        Text("Custom rule")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                        Text((UserRuleDirectory.directory(for: .cleanup).path as NSString).abbreviatingWithTildeInPath)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink3)
                            .textSelection(.enabled)
                    }
                } else {
                    bundledOrigin
                }

                provenanceRow(label: "Source") { sourceRowContent(rule) }

                if let prov = rule.provenance, !prov.isEmpty {
                    authorshipRows(prov)
                }

                provenanceRow(label: "After removal") {
                    Text(afterRemovalSummary(rule))
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                    if let command = rule.regenerateCommand, !command.isEmpty {
                        Text(command)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink3)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }

                provenanceRow(label: "Safeguards") {
                    let safeguards = safeguardSummaries(rule)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(safeguards, id: \.self) { line in
                            Text(line)
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink)
                        }
                    }
                }
            }
            .padding(GargantuaSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .strokeBorder(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sourceRowContent(_ rule: ScanRule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Text(rule.source.name)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                if rule.source.verifySignature {
                    trustTag("Signature verified", color: GargantuaColors.safe)
                }
            }
            if let bundleID = rule.source.bundleID {
                Text(bundleID)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .textSelection(.enabled)
            }
        }
    }

    /// Authorship/review rows, shown only for rules that declare provenance.
    @ViewBuilder
    private func authorshipRows(_ prov: RuleProvenance) -> some View {
        if let author = prov.author {
            provenanceRow(label: "Authored by") {
                Text(author)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }
        }
        if !prov.reviewedBy.isEmpty {
            provenanceRow(label: "Reviewed by") {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(prov.reviewedBy.joined(separator: ", "))
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                    trustTag("Reviewed", color: GargantuaColors.safe)
                }
            }
        }
        if let addedIn = prov.addedIn {
            provenanceRow(label: "Added in") {
                Text(addedIn)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }
        }
    }

    private func provenanceRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                content()
            }
        }
    }

    private func trustTag(_ label: String, color: Color) -> some View {
        Text(label)
            .font(GargantuaFonts.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Summaries

    private func afterRemovalSummary(_ rule: ScanRule) -> String {
        rule.regenerates
            ? "Rebuilt automatically when the app next needs it"
            : "Not automatically rebuilt — removal is permanent"
    }

    /// Plain-English lines describing every guard that narrows this rule. An
    /// empty guard set is itself worth stating — it means a bare path match.
    private func safeguardSummaries(_ rule: ScanRule) -> [String] {
        var lines: [String] = []

        if !rule.skipIfProcessRunning.isEmpty {
            lines.append("Skipped while running: \(rule.skipIfProcessRunning.joined(separator: ", "))")
        }
        if !rule.presenceGuards.isEmpty {
            let paths = rule.presenceGuards.map(\.path).joined(separator: ", ")
            lines.append("Only when present: \(paths)")
        }
        if !rule.contentGuards.isEmpty {
            for guard_ in rule.contentGuards {
                let needles = guard_.contains.joined(separator: ", ")
                lines.append("Skipped if \(guard_.path) contains: \(needles)")
            }
        }
        if let minSize = rule.minSize, minSize > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: minSize, countStyle: .file)
            lines.append("Only files ≥ \(formatted)")
        }

        if lines.isEmpty {
            lines.append("Path match only — no extra guards")
        }
        return lines
    }
}
