import SwiftUI

struct DevArtifactBucketLogoBadge: View {
    let bucket: DevArtifactBucket
    var size: CGFloat = 20
    var showsBackground: Bool = false
    var isMuted: Bool = false

    var body: some View {
        if let tool = developerTool {
            DeveloperToolLogoBadge(
                tool: tool,
                size: size,
                showsBackground: showsBackground,
                isMuted: isMuted
            )
        } else {
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
            .accessibilityHidden(true)
        }
    }

    private var markSize: CGFloat {
        showsBackground ? size * 0.72 : size
    }

    private var developerTool: DeveloperTool? {
        switch bucket.id {
        case "homebrew": .homebrew
        case "docker": .docker
        case "xcode": .xcode
        case "go": .go
        case "rust": .cargo
        default: nil
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch bucket.id {
        case "node":
            nodeMark
        case "python":
            pythonMark
        case "jvm":
            javaMark
        case "dotnet":
            dotnetMark
        case "ruby":
            rubyMark
        case "php":
            phpMark
        default:
            Image(systemName: bucket.icon)
                .font(.system(size: markSize * 0.72, weight: .semibold))
                .foregroundStyle(bucket.tier == .crossCutting ? GargantuaColors.ink : GargantuaColors.ink2)
        }
    }

    private var nodeMark: some View {
        ZStack {
            Hexagon()
                .fill(Color(red: 0.33, green: 0.63, blue: 0.22))
            Text("JS")
                .font(.system(size: markSize * 0.34, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.88, green: 0.95, blue: 0.82))
        }
    }

    private var pythonMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: markSize * 0.18)
                .fill(Color(red: 0.20, green: 0.42, blue: 0.67))
                .frame(width: markSize * 0.74, height: markSize * 0.5)
                .offset(y: -markSize * 0.13)
            RoundedRectangle(cornerRadius: markSize * 0.18)
                .fill(Color(red: 0.99, green: 0.78, blue: 0.24))
                .frame(width: markSize * 0.74, height: markSize * 0.5)
                .offset(y: markSize * 0.13)
            Circle()
                .fill(GargantuaColors.surface1)
                .frame(width: markSize * 0.09, height: markSize * 0.09)
                .offset(x: -markSize * 0.19, y: -markSize * 0.19)
            Circle()
                .fill(GargantuaColors.surface1)
                .frame(width: markSize * 0.09, height: markSize * 0.09)
                .offset(x: markSize * 0.19, y: markSize * 0.19)
        }
    }

    private var javaMark: some View {
        ZStack {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: markSize * 0.78, weight: .semibold))
                .foregroundStyle(Color(red: 0.94, green: 0.33, blue: 0.17))
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: markSize * 0.36, weight: .bold))
                .foregroundStyle(Color(red: 0.15, green: 0.42, blue: 0.76))
                .offset(y: -markSize * 0.33)
        }
    }

    private var dotnetMark: some View {
        RoundedRectangle(cornerRadius: markSize * 0.16)
            .fill(Color(red: 0.36, green: 0.20, blue: 0.78))
            .overlay {
                Text(".NET")
                    .font(.system(size: markSize * 0.25, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
    }

    private var rubyMark: some View {
        Image(systemName: "diamond.fill")
            .font(.system(size: markSize * 0.78, weight: .bold))
            .foregroundStyle(Color(red: 0.82, green: 0.06, blue: 0.11))
    }

    private var phpMark: some View {
        Capsule()
            .fill(Color(red: 0.36, green: 0.39, blue: 0.66))
            .overlay {
                Text("php")
                    .font(.system(size: markSize * 0.3, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
    }
}

private struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let height = rect.height
        let points = [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + height * 0.25),
            CGPoint(x: rect.maxX, y: rect.minY + height * 0.75),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY + height * 0.75),
            CGPoint(x: rect.minX, y: rect.minY + height * 0.25),
        ]
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
