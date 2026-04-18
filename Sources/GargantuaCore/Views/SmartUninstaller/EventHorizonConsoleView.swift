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

    @State private var spinnerFrame = 0
    private let spinnerFrames = ["◜", "◠", "◝", "◞", "◡", "◟"]
    private let spinnerTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

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
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .onReceive(spinnerTimer) { _ in
            spinnerFrame = (spinnerFrame + 1) % spinnerFrames.count
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

                Text(spinnerFrames[spinnerFrame])
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(GargantuaColors.review)
            }

            HStack(spacing: GargantuaSpacing.space5) {
                Text("TARGET: \(targetLabel)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Text("GRAVITY WELL: \(formattedBytes(stream.totalBytes))")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.review)
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
                .foregroundStyle(GargantuaColors.review)
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
                        eventRow(event)
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

    private func eventRow(_ event: ScanProgressEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            Text(displayPath(event.path))
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(rowColor(for: event.outcome))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(badge(for: event.outcome))
                .font(GargantuaFonts.monoPath.weight(.semibold))
                .foregroundStyle(badgeColor(for: event.outcome))
                .frame(width: 72, alignment: .trailing)
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
        case .match: return GargantuaColors.review
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
