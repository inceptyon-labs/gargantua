import SwiftUI

extension EventHorizonConsoleView {
    // MARK: - Rolling log

    var rollingLog: some View {
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

    func eventRow(_ event: ScanProgressEvent, seq: Int) -> some View {
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

    func isSuccessOutcome(_ outcome: ScanProgressEvent.Outcome) -> Bool {
        if case .match = outcome { return true }
        return false
    }

    // MARK: - Row appearance

    func badge(for outcome: ScanProgressEvent.Outcome) -> String {
        switch outcome {
        case .checked: return "✓"
        case .match: return "FOUND"
        case .skipped: return "SKIP"
        case .failed: return "✗"
        }
    }

    func badgeColor(for outcome: ScanProgressEvent.Outcome) -> Color {
        switch outcome {
        case .checked: return GargantuaColors.ink3
        case .match: return GargantuaColors.accretion
        case .skipped: return GargantuaColors.ink4
        case .failed: return GargantuaColors.protected_
        }
    }

    func rowColor(for outcome: ScanProgressEvent.Outcome) -> Color {
        switch outcome {
        case .checked: return GargantuaColors.ink3
        case .match: return GargantuaColors.ink
        case .skipped: return GargantuaColors.ink4
        case .failed: return GargantuaColors.protected_.opacity(0.85)
        }
    }

    func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
