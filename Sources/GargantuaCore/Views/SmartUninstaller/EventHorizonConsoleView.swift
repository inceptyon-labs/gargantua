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

    /// Indices of `stream.events` that have finished spaghettifying during
    /// the current `.executing` phase and should be hidden from the list.
    @State private var swallowedIndices: Set<Int> = []

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
        HStack(spacing: GargantuaSpacing.space2) {
            Text("⟳")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.accretion)
            Text(phaseSubtitle)
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
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
                    ForEach(Array(stream.events.enumerated()), id: \.offset) { index, event in
                        eventRow(event, index: index)
                            .id(index)
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

    private func eventRow(_ event: ScanProgressEvent, index: Int) -> some View {
        SpaghettifyEventRow(
            event: event,
            index: index,
            isExecuting: isExecutingPhase,
            reduceMotion: reduceMotion,
            badge: badge(for: event.outcome),
            badgeColor: badgeColor(for: event.outcome),
            rowColor: rowColor(for: event.outcome),
            displayPath: displayPath(event.path),
            onSwallowed: { swallowedIndices.insert($0) }
        )
        .opacity(swallowedIndices.contains(index) ? 0 : 1)
        .frame(maxHeight: swallowedIndices.contains(index) ? 0 : nil)
        .clipped()
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
        swallowedIndices = []
        activityRate = 0
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

// MARK: - Row

/// Individual log row. Factored out of `EventHorizonConsoleView.body` so it
/// can own its own `@State` for the spaghettify progress without forcing
/// every row into the parent's update loop.
private struct SpaghettifyEventRow: View {
    let event: ScanProgressEvent
    let index: Int
    let isExecuting: Bool
    let reduceMotion: Bool
    let badge: String
    let badgeColor: Color
    let rowColor: Color
    let displayPath: String
    let onSwallowed: (Int) -> Void

    @State private var progress: Double = 0

    private var shouldSpaghettify: Bool {
        guard isExecuting else { return false }
        if case .match = event.outcome { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            Text(Spaghettify.text(displayPath, progress: progress))
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(rowColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(badge)
                .font(GargantuaFonts.monoPath.weight(.semibold))
                .foregroundStyle(badgeColor)
                .frame(width: 72, alignment: .trailing)
        }
        .spaghettify(progress: progress, reduceMotion: reduceMotion)
        .task(id: index) {
            guard shouldSpaghettify else { return }
            try? await Task.sleep(for: .seconds(Spaghettify.dwell))
            if reduceMotion {
                progress = 1
                onSwallowed(index)
                return
            }
            withAnimation(.easeIn(duration: Spaghettify.duration)) {
                progress = 1
            }
            try? await Task.sleep(for: .seconds(Spaghettify.duration))
            onSwallowed(index)
        }
    }
}

// MARK: - Session flag

/// Per-process home for the "once per session" time-dilation easter egg.
/// A struct-level `@State` survives only a single `.executing` phase; this
/// lives for the app's lifetime so the line fires exactly once no matter how
/// many uninstalls the user runs.
@MainActor
final class SingularitySession {
    static let shared = SingularitySession()
    var timeDilationShown = false
    private init() {}
}
