import SwiftUI

struct YAMLHighlightedView: View {
    let yaml: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(yaml.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                highlightedLine(line)
            }
        }
    }

    private func highlightedLine(_ line: String) -> some View {
        let parts = tokenize(line)
        return HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, token in
                Text(token.text)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(token.color)
            }
            Spacer(minLength: 0)
        }
    }

    private func tokenize(_ line: String) -> [YAMLToken] {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return [YAMLToken(text: line, color: GargantuaColors.ink4)]
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") && trimmed.contains(":") && !trimmed.dropFirst(2).hasPrefix("\"") {
            let indent = String(line.prefix(while: { $0 == " " }))
            let afterDash = String(trimmed.dropFirst(2))
            if let colonIdx = afterDash.firstIndex(of: ":") {
                let key = String(afterDash[afterDash.startIndex ..< colonIdx])
                let rest = String(afterDash[afterDash.index(after: colonIdx)...])
                return [
                    YAMLToken(text: indent + "- ", color: GargantuaColors.ink3),
                    YAMLToken(text: key, color: GargantuaColors.accent),
                    YAMLToken(text: ":", color: GargantuaColors.ink3),
                    YAMLToken(text: rest, color: valueColor(rest.trimmingCharacters(in: .whitespaces))),
                ]
            }
        }

        if trimmed.hasPrefix("- ") {
            let indent = String(line.prefix(while: { $0 == " " }))
            let value = String(trimmed.dropFirst(2))
            return [
                YAMLToken(text: indent + "- ", color: GargantuaColors.ink3),
                YAMLToken(text: value, color: valueColor(value)),
            ]
        }

        if let colonIdx = line.firstIndex(of: ":") {
            let key = String(line[line.startIndex ..< colonIdx])
            let rest = String(line[line.index(after: colonIdx)...])
            if rest.isEmpty || rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return [
                    YAMLToken(text: key, color: GargantuaColors.accent),
                    YAMLToken(text: ":" + rest, color: GargantuaColors.ink3),
                ]
            }
            return [
                YAMLToken(text: key, color: GargantuaColors.accent),
                YAMLToken(text: ":", color: GargantuaColors.ink3),
                YAMLToken(text: rest, color: valueColor(rest.trimmingCharacters(in: .whitespaces))),
            ]
        }

        return [YAMLToken(text: line, color: GargantuaColors.ink)]
    }

    private func valueColor(_ value: String) -> Color {
        if value == "true" || value == "false" {
            return GargantuaColors.review
        }
        if Double(value) != nil {
            return GargantuaColors.review
        }
        if value.hasPrefix("\"") {
            return GargantuaColors.safe
        }
        if value == "safe" || value == "review" || value == "protected" {
            return safetyValueColor(value)
        }
        return GargantuaColors.ink
    }

    private func safetyValueColor(_ value: String) -> Color {
        switch value {
        case "safe": GargantuaColors.safe
        case "review": GargantuaColors.review
        case "protected": GargantuaColors.protected_
        default: GargantuaColors.ink
        }
    }
}

private struct YAMLToken {
    let text: String
    let color: Color
}
