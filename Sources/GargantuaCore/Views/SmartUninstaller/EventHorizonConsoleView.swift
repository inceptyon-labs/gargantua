import SwiftUI

/// Live terminal-style console that streams filesystem paths being
/// inspected during the Smart Uninstaller flow, wrapped in Gargantua's
/// space-horror aesthetic.
///
/// Replaces the static `centeredStatus` placeholders with something
/// that (a) proves work is happening and (b) gives the user visibility
/// into what the app is actually doing. Real data in a good costume.
public struct EventHorizonConsoleView: View {
    let phase: SmartUninstallerPhase
    @Bindable var stream: PathStreamViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stable sequence IDs of events that have finished spaghettifying
    /// during the current `.executing` phase. Using sequence numbers
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

    public init(phase: SmartUninstallerPhase, stream: PathStreamViewModel) {
        self.phase = phase
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
        .onChange(of: phaseKey) { _, _ in resetPhaseTracking() }
        .onChange(of: stream.events.count) { oldCount, newCount in
            updateActivityRate(delta: max(newCount - oldCount, 0))
            tripTimeDilationIfDue()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text("ENDURANCE · UNINSTALL SEQUENCE")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(2)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                AccretionDiskView(activityRate: activityRate)
            }

            HStack(spacing: GargantuaSpacing.space5) {
                Text("TARGET: \(targetLabel)")
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
            Text(phaseSubtitle)
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
            if isInProgressPhase {
                activityEllipsis
            }
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

    private var isInProgressPhase: Bool {
        switch phase {
        case .loadingApps, .scanning, .executing: true
        default: false
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
            shouldSpaghettify: isExecutingPhase && postBaseline && isSuccessOutcome(event.outcome),
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

    /// A hashable key derived from the phase enum so `onChange` fires only
    /// when the bucket (not the associated plan) changes.
    private var phaseKey: String {
        switch phase {
        case .idle: "idle"
        case .loadingApps: "loadingApps"
        case .pickingApp: "pickingApp"
        case .scanning: "scanning"
        case .reviewingPlan: "reviewingPlan"
        case .executing: "executing"
        case .summary: "summary"
        case .failed: "failed"
        }
    }

    private var isExecutingPhase: Bool {
        if case .executing = phase { return true }
        return false
    }

    private func resetPhaseTracking() {
        phaseEnteredAt = Date()
        swallowedSeqs = []
        activityRate = 0
        // Anchor the executing baseline to the next sequence ID that will
        // be assigned. Any event already in the buffer belongs to a prior
        // phase (e.g. scan matches) and must not be spaghettified.
        executingBaselineSeq = stream.firstSequence + stream.events.count
        if !isExecutingPhase {
            showTimeDilation = false
        }
    }

    private func updateActivityRate(delta: Int) {
        guard delta > 0 else { return }
        // Exponential moving average so the disk reacts to surges without
        // thrashing on single events.
        let instantaneous = Double(delta) * 10  // events arrive ~100ms apart in bursts
        activityRate = (activityRate * 0.7) + (instantaneous * 0.3)
    }

    private func tripTimeDilationIfDue() {
        guard isExecutingPhase, !showTimeDilation else { return }
        let elapsed = Date().timeIntervalSince(phaseEnteredAt)
        guard elapsed >= 10 else { return }
        guard !SingularitySession.shared.timeDilationShown else { return }
        SingularitySession.shared.timeDilationShown = true
        withAnimation(.easeIn(duration: 0.8)) {
            showTimeDilation = true
        }
    }

    // MARK: - Derived strings

    private var targetLabel: String {
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
        case .failed:
            return "—"
        }
    }

    private var phaseSubtitle: String {
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
        case .failed:
            return "Signal lost in the accretion disk."
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
