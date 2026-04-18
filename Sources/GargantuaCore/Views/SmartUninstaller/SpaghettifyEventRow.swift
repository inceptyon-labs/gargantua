import SwiftUI

/// Individual log row for `EventHorizonConsoleView`. Owns its own `@State`
/// for the spaghettify progress so every row isn't forced into the parent's
/// update loop on every event.
struct SpaghettifyEventRow: View {
    let event: ScanProgressEvent
    let seq: Int
    let shouldSpaghettify: Bool
    let reduceMotion: Bool
    let badge: String
    let badgeColor: Color
    let rowColor: Color
    let displayPath: String
    let onSwallowed: (Int) -> Void

    @State private var progress: Double = 0

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
        .task(id: seq) {
            guard shouldSpaghettify else { return }
            // Respect cancellation: SwiftUI cancels `.task` when the view is
            // replaced (phase change, ring-buffer rollover, identity churn).
            // `try? await Task.sleep` swallows the cancellation error, so the
            // closure would continue mutating stale state — check explicitly.
            do { try await Task.sleep(for: .seconds(Spaghettify.dwell)) } catch { return }
            if Task.isCancelled { return }
            if reduceMotion {
                progress = 1
                onSwallowed(seq)
                return
            }
            withAnimation(.easeIn(duration: Spaghettify.duration)) {
                progress = 1
            }
            do { try await Task.sleep(for: .seconds(Spaghettify.duration)) } catch { return }
            if Task.isCancelled { return }
            onSwallowed(seq)
        }
    }
}

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
