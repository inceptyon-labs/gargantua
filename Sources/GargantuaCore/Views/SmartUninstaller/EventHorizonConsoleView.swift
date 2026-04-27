import SwiftUI

/// Caller-supplied view-model for the EventHorizon console.
///
/// Decouples the console from any specific phase enum so the same chrome can
/// be driven by Smart Uninstaller, Deep Clean, Dev Purge, etc. Each tool
/// derives a context from its own phase and passes it in.
public struct EventHorizonContext: Equatable {
    /// Top-bar label, e.g. `"ENDURANCE · UNINSTALL SEQUENCE"` or
    /// `"ENDURANCE · DEEP CLEAN SWEEP"`.
    public let header: String
    /// Inline target identifier shown after `TARGET:`, e.g. an app name or
    /// a profile name. Pass `"—"` when no target makes sense.
    public let target: String
    /// Subtitle line under the header (italic, paired with the activity disk).
    /// When `subtitlePool` is non-empty and `isInProgress` is true, the console
    /// rotates through the pool instead of showing this static value.
    public let subtitle: String
    /// Rotating pool of status lines shown during active work. Cycled every
    /// few seconds so the UI signals ongoing activity even between log events.
    /// Leave empty to show the static `subtitle` only.
    public let subtitlePool: [String]
    /// Whether the console is still working — drives the spinning indicator
    /// and the trailing animated ellipsis.
    public let isInProgress: Bool
    /// Whether the console is in the destructive phase — gates the spaghettify
    /// swallow effect on `.match` events.
    public let isExecuting: Bool
    /// Stable identity for `onChange` reset hooks. Distinct values trigger a
    /// re-anchoring of the executing-baseline and clear the swallowed set.
    public let phaseKey: String

    public init(
        header: String,
        target: String,
        subtitle: String,
        subtitlePool: [String] = [],
        isInProgress: Bool,
        isExecuting: Bool,
        phaseKey: String
    ) {
        self.header = header
        self.target = target
        self.subtitle = subtitle
        self.subtitlePool = subtitlePool
        self.isInProgress = isInProgress
        self.isExecuting = isExecuting
        self.phaseKey = phaseKey
    }
}

extension EventHorizonContext {
    /// Build a context from a `SmartUninstallerPhase`. Keeps the original
    /// uninstall copy so existing screens render identically.
    public static func uninstaller(phase: SmartUninstallerPhase) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · UNINSTALL SEQUENCE",
            target: uninstallTarget(for: phase),
            subtitle: uninstallSubtitle(for: phase),
            subtitlePool: uninstallSubtitlePool(for: phase),
            isInProgress: uninstallInProgress(for: phase),
            isExecuting: uninstallExecuting(for: phase),
            phaseKey: uninstallPhaseKey(for: phase)
        )
    }

    private static func uninstallTarget(for phase: SmartUninstallerPhase) -> String {
        switch phase {
        case .idle, .loadingApps:
            return "/Applications · Launch Services"
        case .pickingApp:
            return "—"
        case .scanning(let app):
            return app.displayName ?? app.name
        case .reviewingPlan(let plan):
            return plan.app.displayName ?? plan.app.name
        case .executing(let plan):
            return plan.app.displayName ?? plan.app.name
        case .summary(let plan, _):
            return plan.app.displayName ?? plan.app.name
        case .batchScanning(let completed, let total):
            return "BATCH \(completed)/\(total)"
        case .batchExecuting(let completed, let total):
            return "BATCH \(completed)/\(total)"
        case .batchSummary(let results):
            return "BATCH \(results.count) apps"
        case .failed:
            return "—"
        }
    }

    private static func uninstallSubtitle(for phase: SmartUninstallerPhase) -> String {
        switch phase {
        case .idle, .loadingApps:
            return "Surveying nearby star systems"
        case .pickingApp:
            return "Awaiting mission parameters"
        case .scanning(let app):
            return "Tracing gravitational echoes from \(app.displayName ?? app.name)"
        case .reviewingPlan:
            return "Plan locked. Awaiting authorization."
        case .executing:
            return "Crossing the event horizon"
        case .summary(let plan, _):
            let name = plan.app.displayName ?? plan.app.name
            return "Signal recovered. \(name) has passed into Gargantua."
        case .batchScanning:
            return "Tracing gravitational echoes across the batch"
        case .batchExecuting:
            return "Crossing the event horizon"
        case .batchSummary:
            return "Signal recovered. Batch artifacts have passed into Gargantua."
        case .failed:
            return "Signal lost in the accretion disk."
        }
    }

    private static func uninstallSubtitlePool(for phase: SmartUninstallerPhase) -> [String] {
        switch phase {
        case .scanning(let app):
            let name = app.displayName ?? app.name
            return [
                "Tracing gravitational echoes from \(name)",
                "Mapping \(name)'s orbital debris field",
                "Cataloguing artifact mass across support constellation",
                "Scanning container boundary topology",
                "Measuring sandbox curvature anomalies",
                "Probing preference manifold geometry",
                "Surveying cache residue in deep orbit",
                "Calibrating removal trajectory",
                "Detecting stray framework signatures",
                "Charting plugin accretion layers",
            ]
        case .batchScanning:
            return [
                "Tracing gravitational echoes across the batch",
                "Mapping multi-app debris fields",
                "Cataloguing artifact mass across targets",
                "Scanning container boundary topology",
                "Calibrating batch removal trajectories",
                "Surveying cache residue in deep orbit",
                "Probing preference manifold geometry",
                "Charting plugin accretion layers",
            ]
        case .executing, .batchExecuting:
            return [
                "Crossing the event horizon",
                "Spaghettification sequence active",
                "Matter absorption nominal",
                "Tidal compression underway",
                "Singularity ingestion in progress",
                "No signal can escape",
            ]
        default:
            return []
        }
    }

    private static func uninstallInProgress(for phase: SmartUninstallerPhase) -> Bool {
        switch phase {
        case .loadingApps, .scanning, .executing, .batchScanning, .batchExecuting: true
        default: false
        }
    }

    private static func uninstallExecuting(for phase: SmartUninstallerPhase) -> Bool {
        switch phase {
        case .executing, .batchExecuting: true
        default: false
        }
    }

    private static func uninstallPhaseKey(for phase: SmartUninstallerPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .loadingApps: "loadingApps"
        case .pickingApp: "pickingApp"
        case .scanning: "scanning"
        case .reviewingPlan: "reviewingPlan"
        case .executing: "executing"
        case .summary: "summary"
        case .batchScanning: "batchScanning"
        case .batchExecuting: "batchExecuting"
        case .batchSummary: "batchSummary"
        case .failed: "failed"
        }
    }

    /// Build a context from a `DeepCleanPhase` + profile name. Mirrors the
    /// uninstaller's vocabulary so the two surfaces feel the same.
    public static func deepClean(
        phase: DeepCleanPhase,
        profileName: String
    ) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · DEEP CLEAN SWEEP",
            target: profileName,
            subtitle: deepCleanSubtitle(for: phase, profileName: profileName),
            subtitlePool: deepCleanSubtitlePool(for: phase, profileName: profileName),
            isInProgress: phase == .scanning || phase == .cleaning,
            isExecuting: phase == .cleaning,
            phaseKey: deepCleanPhaseKey(for: phase)
        )
    }

    private static func deepCleanSubtitle(for phase: DeepCleanPhase, profileName: String) -> String {
        switch phase {
        case .idle: return "Awaiting mission parameters"
        case .scanning: return "Tracing gravitational echoes from \(profileName)"
        case .results: return "Plan locked. Awaiting authorization."
        case .cleaning: return "Crossing the event horizon"
        case .summary: return "Signal recovered. Gargantua has consumed the cache."
        }
    }

    private static func deepCleanSubtitlePool(for phase: DeepCleanPhase, profileName: String) -> [String] {
        switch phase {
        case .scanning:
            return [
                "Tracing gravitational echoes from \(profileName)",
                "Mapping accretion disk topology",
                "Calibrating tidal force sensors",
                "Surveying event horizon boundary layers",
                "Probing for reclaimable mass",
                "Measuring spacetime debris density",
                "Detecting substellar cache fields",
                "Charting the gravitational lens",
                "Analyzing residual quantum foam",
                "Sweeping the accretion corridor",
                "Cataloguing orbital cache debris",
                "Scanning for entropy accumulation",
            ]
        case .cleaning:
            return [
                "Crossing the event horizon",
                "Spaghettification sequence active",
                "Matter absorption nominal",
                "Tidal compression underway",
                "Singularity ingestion in progress",
                "No signal can escape",
            ]
        default:
            return []
        }
    }

    private static func deepCleanPhaseKey(for phase: DeepCleanPhase) -> String {
        switch phase {
        case .idle: "deepClean.idle"
        case .scanning: "deepClean.scanning"
        case .results: "deepClean.results"
        case .cleaning: "deepClean.cleaning"
        case .summary: "deepClean.summary"
        }
    }

    /// Build a context for Dev Artifact Purge.
    public static func devPurge(
        phase: DeepCleanPhase,
        profileName: String
    ) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · DEV ARTIFACT PURGE",
            target: profileName,
            subtitle: devPurgeSubtitle(for: phase, profileName: profileName),
            subtitlePool: devPurgeSubtitlePool(for: phase, profileName: profileName),
            isInProgress: phase == .scanning || phase == .cleaning,
            isExecuting: phase == .cleaning,
            phaseKey: devPurgePhaseKey(for: phase)
        )
    }

    private static func devPurgeSubtitle(for phase: DeepCleanPhase, profileName: String) -> String {
        switch phase {
        case .idle: return "Awaiting mission parameters"
        case .scanning: return "Tracing dev artifact debris (\(profileName))"
        case .results: return "Plan locked. Awaiting authorization."
        case .cleaning: return "Crossing the event horizon"
        case .summary: return "Signal recovered. The build artifacts are gone."
        }
    }

    private static func devPurgeSubtitlePool(for phase: DeepCleanPhase, profileName: String) -> [String] {
        switch phase {
        case .scanning:
            return [
                "Tracing dev artifact debris (\(profileName))",
                "Mapping build artifact constellations",
                "Probing derived data singularity",
                "Scanning simulator cache topology",
                "Detecting stale index store fragments",
                "Measuring Swift package cache density",
                "Surveying archive residue fields",
                "Cataloguing incremental build debris",
                "Charting module map accretion layers",
                "Analyzing orphaned framework signatures",
            ]
        case .cleaning:
            return [
                "Crossing the event horizon",
                "Spaghettification sequence active",
                "Build artifacts absorbed",
                "Tidal compression underway",
                "Singularity ingestion in progress",
            ]
        default:
            return []
        }
    }

    private static func devPurgePhaseKey(for phase: DeepCleanPhase) -> String {
        switch phase {
        case .idle: "devPurge.idle"
        case .scanning: "devPurge.scanning"
        case .results: "devPurge.results"
        case .cleaning: "devPurge.cleaning"
        case .summary: "devPurge.summary"
        }
    }
}

/// Live terminal-style console that streams filesystem paths being
/// inspected during a long-running operation, wrapped in Gargantua's
/// space-horror aesthetic.
///
/// Originally built for Smart Uninstaller; generalized to accept an
/// `EventHorizonContext` so any tool with a `PathStreamViewModel` can
/// drive it (Deep Clean, Dev Purge, etc.).
public struct EventHorizonConsoleView: View {
    let context: EventHorizonContext
    @Bindable var stream: PathStreamViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stable sequence IDs of events that have finished spaghettifying
    /// during the current `isExecuting` phase. Using sequence numbers
    /// (`PathStreamViewModel.firstSequence + offset`) rather than array
    /// offsets keeps this set correct when the ring buffer rolls over.
    @State private var swallowedSeqs: Set<Int> = []

    /// Sequence number of the first event that belongs to the current
    /// executing phase. Match events from earlier phases (scanning) are
    /// below this threshold and must not be spaghettified.
    @State private var executingBaselineSeq: Int = 0

    /// Wall-clock the current phase was entered. Used to gate the
    /// time-dilation easter egg line.
    @State private var phaseEnteredAt: Date = .distantPast

    /// Events-per-second approximation used to modulate accretion-disk speed.
    @State private var activityRate: Double = 0

    /// Whether the time-dilation line has crossed its 10-second threshold
    /// for the current executing phase.
    @State private var showTimeDilation = false

    public init(context: EventHorizonContext, stream: PathStreamViewModel) {
        self.context = context
        self._stream = Bindable(stream)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            header
            subtitleLine
            rollingLog
            footer
            if showTimeDilation {
                timeDilationLine
                    .transition(.opacity)
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .onAppear { resetPhaseTracking() }
        .onChange(of: context.phaseKey) { _, _ in resetPhaseTracking() }
        .onChange(of: stream.events.count) { oldCount, newCount in
            updateActivityRate(delta: max(newCount - oldCount, 0))
            tripTimeDilationIfDue()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text(context.header)
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(2)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                AccretionDiskView(activityRate: activityRate)
            }

            HStack(spacing: GargantuaSpacing.space5) {
                Text("TARGET: \(context.target)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Text("GRAVITY WELL: \(formattedBytes(stream.totalBytes))")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.accretion)
            }

            Text("[TARS] Humor: 60% · Honesty: 95% · Pragmatism: 100%")
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    private var subtitleLine: some View {
        // Spinning disk sits right next to the phase text so motion is always
        // in eyeline during long scans — the header disk can be easy to miss
        // on big apps during quiet event stretches.
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: activityRate, size: 11)
            subtitleText
            if context.isInProgress {
                activityEllipsis
            }
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        let pool = context.subtitlePool
        if context.isInProgress && pool.count > 1 && !reduceMotion {
            // Rotate through the pool every 4 seconds. Using a TimelineView
            // with a periodic schedule keeps SwiftUI from re-evaluating the
            // whole body — only this subtree updates on each tick.
            TimelineView(.periodic(from: .now, by: 4.0)) { tlContext in
                let step = Int(tlContext.date.timeIntervalSinceReferenceDate / 4.0) % pool.count
                Text(pool[step])
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .transition(.opacity)
                    .id(step)
                    .animation(.easeInOut(duration: 0.5), value: step)
            }
        } else {
            Text(pool.first ?? context.subtitle)
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
        }
    }

    @ViewBuilder
    private var activityEllipsis: some View {
        // Both branches reserve the same width so toggling reduce-motion
        // doesn't shift the subtitle baseline.
        if reduceMotion {
            Text("…")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.45)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3
                Text(String(repeating: ".", count: step + 1))
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Rolling log

    private var rollingLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if stream.events.isEmpty {
                        Text("waiting for gravitational signal…")
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink4)
                            .padding(.vertical, GargantuaSpacing.space2)
                    }
                    ForEach(Array(stream.events.enumerated()), id: \.offset) { offset, event in
                        let seq = stream.firstSequence + offset
                        eventRow(event, seq: seq)
                            .id(seq)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("tail")
                }
                .padding(GargantuaSpacing.space3)
            }
            .background(GargantuaColors.surface1)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
            .frame(maxHeight: .infinity)
            .onChange(of: stream.events.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("tail", anchor: .bottom)
                }
            }
        }
    }

    private func eventRow(_ event: ScanProgressEvent, seq: Int) -> some View {
        let postBaseline = seq >= executingBaselineSeq
        return SpaghettifyEventRow(
            event: event,
            seq: seq,
            shouldSpaghettify: context.isExecuting && postBaseline && isSuccessOutcome(event.outcome),
            reduceMotion: reduceMotion,
            badge: badge(for: event.outcome),
            badgeColor: badgeColor(for: event.outcome),
            rowColor: rowColor(for: event.outcome),
            displayPath: displayPath(event.path),
            onSwallowed: { swallowedSeqs.insert($0) }
        )
        .opacity(swallowedSeqs.contains(seq) ? 0 : 1)
        .frame(maxHeight: swallowedSeqs.contains(seq) ? 0 : nil)
        .clipped()
    }

    private func isSuccessOutcome(_ outcome: ScanProgressEvent.Outcome) -> Bool {
        if case .match = outcome { return true }
        return false
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: GargantuaSpacing.space5) {
            Text("EVENT HORIZON CROSSINGS: \(stream.matchCount)")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)

            Text("TIDAL FORCES: \(stream.failureCount == 0 ? "nominal" : "anomalous")")
                .font(GargantuaFonts.caption)
                .foregroundStyle(stream.failureCount == 0 ? GargantuaColors.ink2 : GargantuaColors.protected_)

            Spacer()
        }
    }

    private var timeDilationLine: some View {
        Text("Δt: 7 minutes per second on Miller's planet")
            .font(GargantuaFonts.caption.italic())
            .foregroundStyle(GargantuaColors.ink3)
    }

    // MARK: - Phase / activity tracking

    private func resetPhaseTracking() {
        phaseEnteredAt = Date()
        swallowedSeqs = []
        activityRate = 0
        // Anchor the executing baseline to the next sequence ID that will
        // be assigned. Any event already in the buffer belongs to a prior
        // phase (e.g. scan matches) and must not be spaghettified.
        executingBaselineSeq = stream.firstSequence + stream.events.count
        if !context.isExecuting {
            showTimeDilation = false
        }
    }

    private func updateActivityRate(delta: Int) {
        guard delta > 0 else { return }
        // Exponential moving average so the disk reacts to surges without
        // thrashing on single events.
        let instantaneous = Double(delta) * 10 // events arrive ~100ms apart in bursts
        activityRate = (activityRate * 0.7) + (instantaneous * 0.3)
    }

    private func tripTimeDilationIfDue() {
        guard context.isExecuting, !showTimeDilation else { return }
        let elapsed = Date().timeIntervalSince(phaseEnteredAt)
        guard elapsed >= 10 else { return }
        guard !SingularitySession.shared.timeDilationShown else { return }
        SingularitySession.shared.timeDilationShown = true
        withAnimation(.easeIn(duration: 0.8)) {
            showTimeDilation = true
        }
    }

    // MARK: - Row appearance

    private func badge(for outcome: ScanProgressEvent.Outcome) -> String {
        switch outcome {
        case .checked: return "✓"
        case .match: return "FOUND"
        case .skipped: return "SKIP"
        case .failed: return "✗"
        }
    }

    private func badgeColor(for outcome: ScanProgressEvent.Outcome) -> Color {
        switch outcome {
        case .checked: return GargantuaColors.ink3
        case .match: return GargantuaColors.accretion
        case .skipped: return GargantuaColors.ink4
        case .failed: return GargantuaColors.protected_
        }
    }

    private func rowColor(for outcome: ScanProgressEvent.Outcome) -> Color {
        switch outcome {
        case .checked: return GargantuaColors.ink3
        case .match: return GargantuaColors.ink
        case .skipped: return GargantuaColors.ink4
        case .failed: return GargantuaColors.protected_.opacity(0.85)
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
