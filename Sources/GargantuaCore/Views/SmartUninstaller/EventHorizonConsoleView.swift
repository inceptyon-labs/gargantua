import SwiftUI

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
    /// Invoked when the user severs the tether (cancels). Optional — when
    /// `nil`, the Sever Tether button is hidden. Callers that wire this up
    /// must also drop the in-flight `Task` so the abort actually halts work.
    let onAbort: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Stable sequence IDs of events that have finished spaghettifying
    /// during the current `isExecuting` phase. Using sequence numbers
    /// (`PathStreamViewModel.firstSequence + offset`) rather than array
    /// offsets keeps this set correct when the ring buffer rolls over.
    @State var swallowedSeqs: Set<Int> = []

    /// Sequence number of the first event that belongs to the current
    /// executing phase. Match events from earlier phases (scanning) are
    /// below this threshold and must not be spaghettified.
    @State var executingBaselineSeq: Int = 0

    /// Wall-clock the current phase was entered. Used to gate the
    /// time-dilation easter egg line.
    @State private var phaseEnteredAt: Date = .distantPast

    /// Events-per-second approximation used to modulate accretion-disk speed.
    @State private var activityRate: Double = 0

    /// Whether the time-dilation line has crossed its 10-second threshold
    /// for the current executing phase.
    @State private var showTimeDilation = false

    public init(
        context: EventHorizonContext,
        stream: PathStreamViewModel,
        onAbort: (() -> Void)? = nil
    ) {
        self.context = context
        self._stream = Bindable(stream)
        self.onAbort = onAbort
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
            Text(context.header)
                .font(GargantuaFonts.sectionLabel)
                .tracking(2)
                .foregroundStyle(GargantuaColors.ink2)

            HStack(spacing: GargantuaSpacing.space5) {
                Text("TARGET: \(context.target)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Text("GRAVITY WELL: \(formattedBytes(stream.totalBytes))")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.accretion)
            }

            Text(kippLine)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    /// Live KIPP status line. Honesty stays at 100 — we never lie about what
    /// got cleaned. Humor stays at 0 — KIPP is settable but nobody's bothered.
    /// Salvage is the running match count so the user can watch it climb.
    private var kippLine: String {
        let salvage: String
        if context.isInProgress {
            salvage = "\(stream.matchCount) artifact\(stream.matchCount == 1 ? "" : "s")"
        } else {
            salvage = "standby"
        }
        return "[KIPP] Humor: 0% · Honesty: 100% · Salvage: \(salvage)"
    }

    private var subtitleLine: some View {
        // Spinning disk sits in eyeline next to the phase text so motion is
        // always visible during long scans, and the cosmic phrase changes when
        // the scanner crosses into a new directory — the metaphor itself is
        // the activity signal.
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: activityRate, size: 11)
            subtitleText
        }
    }

    /// Cosmic phrase bound to the current scan domain when possible. When the
    /// scanner is actively walking a recognized root (`~/Library/Caches`,
    /// `DerivedData`, etc.), the phrase describes that domain and the trailing
    /// metadata anchors it to a real path count. When no domain is known yet
    /// or the path falls outside the mapping, falls back to the per-tool
    /// rotating pool so first-paint and edge cases still feel alive.
    @ViewBuilder
    private var subtitleText: some View {
        if let domain = currentDomain {
            HStack(spacing: GargantuaSpacing.space2) {
                Text(domain.phrase)
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                Text("·")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink4)
                Text("\(stream.matchCount + checkedCount) paths")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
                Text("·")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink4)
                Text(domain.displayRoot)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .id(domain.displayRoot)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: domain.displayRoot)
        } else {
            fallbackSubtitle
        }
    }

    /// Per-tool rotating pool, used when no scan path has arrived yet or the
    /// current path falls outside our domain mappings.
    @ViewBuilder
    private var fallbackSubtitle: some View {
        let pool = context.subtitlePool
        if context.isInProgress && pool.count > 1 && !reduceMotion {
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

    /// Resolve the cosmic domain for the latest path emitted by the scanner.
    /// Only consults the live stream while the console is in progress so a
    /// stale tail event from a prior phase doesn't leak into idle copy.
    private var currentDomain: CosmicDomain? {
        guard context.isInProgress else { return nil }
        guard let lastPath = stream.events.last?.path else { return nil }
        return EventHorizonContext.cosmicDomain(forPath: lastPath)
    }

    /// Approximate inspected-path count: matches are tracked exactly, but
    /// "checked" outcomes aren't — the buffer is bounded so we expose the
    /// in-buffer count as a floor. Good enough to give the user a number that
    /// climbs visibly during long scans.
    private var checkedCount: Int {
        stream.events.reduce(0) { count, event in
            if case .checked = event.outcome { return count + 1 }
            return count
        }
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

            if let onAbort, context.isInProgress {
                severTetherButton(action: onAbort)
            }
        }
    }

    /// Endurance docking reference — sever the tether, return to safe orbit.
    /// Copy switches based on phase so the user knows whether they're aborting
    /// a survey or halting an in-flight cleanup.
    private func severTetherButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 11, weight: .semibold))
                Text(context.isExecuting ? "Halt Cleanup" : "Sever Tether")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                    .stroke(GargantuaColors.borderEm, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(context.isExecuting
            ? "Halt cleanup. Items already removed stay removed."
            : "Sever the tether and return to start.")
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

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
