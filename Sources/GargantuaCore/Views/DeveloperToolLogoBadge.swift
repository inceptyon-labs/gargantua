import AppKit
import SwiftUI

struct DeveloperToolLogoBadge: View {
    let tool: DeveloperTool
    var size: CGFloat = 28
    var showsBackground: Bool = true
    var isMuted: Bool = false

    @State private var appIcon: NSImage?

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(GargantuaColors.surface1)
            }
            mark
                .frame(width: markSize, height: markSize)
        }
        .frame(width: size, height: size)
        .overlay {
            if showsBackground {
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.borderSoft, lineWidth: 1)
            }
        }
        .saturation(isMuted ? 0 : 1)
        .opacity(isMuted ? 0.55 : 1)
        .task(id: tool.id) {
            appIcon = Self.loadAppIcon(for: tool)
        }
        .accessibilityHidden(true)
    }

    private var markSize: CGFloat {
        showsBackground ? size * 0.72 : size
    }

    @ViewBuilder
    private var mark: some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
        } else {
            switch tool {
            case .homebrew:
                homebrewMark
            case .docker:
                dockerMark
            case .xcode:
                xcodeFallbackMark
            case .pnpm:
                pnpmMark
            case .go:
                goMark
            case .cargo:
                cargoMark
            }
        }
    }

    private var homebrewMark: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: max(2, size * 0.08))
                .fill(Color(red: 0.93, green: 0.61, blue: 0.16))
                .frame(width: markSize * 0.68, height: markSize * 0.62)
                .offset(x: -markSize * 0.08)
            RoundedRectangle(cornerRadius: max(2, size * 0.08))
                .stroke(Color(red: 0.93, green: 0.61, blue: 0.16), lineWidth: max(1.5, size * 0.08))
                .frame(width: markSize * 0.32, height: markSize * 0.38)
                .offset(x: markSize * 0.04)
            RoundedRectangle(cornerRadius: max(1, size * 0.05))
                .fill(Color(red: 0.17, green: 0.12, blue: 0.07))
                .frame(width: markSize * 0.42, height: max(1.5, markSize * 0.08))
                .offset(x: -markSize * 0.14, y: -markSize * 0.14)
        }
    }

    private var dockerMark: some View {
        VStack(spacing: markSize * 0.06) {
            VStack(alignment: .leading, spacing: markSize * 0.04) {
                HStack(spacing: markSize * 0.04) {
                    dockerBlock.opacity(0)
                    dockerBlock
                    dockerBlock.opacity(0)
                }
                HStack(spacing: markSize * 0.04) {
                    dockerBlock
                    dockerBlock
                    dockerBlock
                }
            }
            RoundedRectangle(cornerRadius: markSize * 0.08)
                .fill(Color(red: 0.08, green: 0.46, blue: 0.86))
                .frame(width: markSize * 0.82, height: max(2, markSize * 0.12))
        }
    }

    private var dockerBlock: some View {
        RoundedRectangle(cornerRadius: max(1, markSize * 0.035))
            .fill(Color(red: 0.08, green: 0.55, blue: 0.95))
            .frame(width: markSize * 0.22, height: markSize * 0.18)
    }

    private var xcodeFallbackMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: markSize * 0.18)
                .fill(Color(red: 0.12, green: 0.45, blue: 0.92))
            Image(systemName: "hammer.fill")
                .font(.system(size: markSize * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var pnpmMark: some View {
        VStack(spacing: markSize * 0.06) {
            ForEach(0 ..< 3, id: \.self) { row in
                HStack(spacing: markSize * 0.06) {
                    ForEach(0 ..< 3, id: \.self) { column in
                        RoundedRectangle(cornerRadius: max(1, markSize * 0.035))
                            .fill(pnpmColor(row: row, column: column))
                            .frame(width: markSize * 0.25, height: markSize * 0.25)
                    }
                }
            }
        }
    }

    private func pnpmColor(row: Int, column: Int) -> Color {
        if row == 1 && column == 1 {
            return Color(red: 0.16, green: 0.16, blue: 0.15)
        }
        return Color(red: 0.95, green: 0.72, blue: 0.14)
    }

    private var goMark: some View {
        Text("Go")
            .font(.system(size: markSize * 0.58, weight: .bold, design: .rounded))
            .italic()
            .foregroundStyle(Color(red: 0.08, green: 0.68, blue: 0.78))
            .minimumScaleFactor(0.6)
    }

    private var cargoMark: some View {
        ZStack {
            Image(systemName: "gearshape.fill")
                .font(.system(size: markSize * 0.86, weight: .semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.53, blue: 0.38))
            Text("R")
                .font(.system(size: markSize * 0.3, weight: .black, design: .rounded))
                .foregroundStyle(GargantuaColors.surface1)
        }
    }

    @MainActor
    private static func loadAppIcon(for tool: DeveloperTool) -> NSImage? {
        for path in appIconPaths(for: tool) where FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            if icon.isValid {
                return icon
            }
        }
        return nil
    }

    private static func appIconPaths(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .docker:
            ["/Applications/Docker.app", "/Applications/Docker Desktop.app"]
        case .xcode:
            ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"]
        case .homebrew, .pnpm, .go, .cargo:
            []
        }
    }
}
