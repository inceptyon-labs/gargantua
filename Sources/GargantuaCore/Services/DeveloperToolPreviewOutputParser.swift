import Foundation

extension DeveloperToolPreviewAdapter {
    static func parsePreview(
        tool: DeveloperTool,
        commandPreview: [String],
        output: String
    ) -> [DeveloperToolPreviewItem] {
        DeveloperToolPreviewOutputParser.parsePreview(
            tool: tool,
            commandPreview: commandPreview,
            output: output
        )
    }

    static func parseDockerSystemDFJSON(
        output: String,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        DeveloperToolPreviewOutputParser.parseDockerSystemDFJSON(
            output: output,
            commandPreview: commandPreview
        )
    }

    static func parseDockerReclaimable(_ token: String) -> Int64? {
        DeveloperToolPreviewOutputParser.parseDockerReclaimable(token)
    }

    static func parseFirstSize(in line: String) -> Int64? {
        DeveloperToolPreviewOutputParser.parseFirstSize(in: line)
    }

    static func parseSize(_ token: String) -> Int64? {
        DeveloperToolPreviewOutputParser.parseSize(token)
    }
}

enum DeveloperToolPreviewOutputParser {
    static func parsePreview(
        tool: DeveloperTool,
        commandPreview: [String],
        output: String
    ) -> [DeveloperToolPreviewItem] {
        switch tool {
        case .homebrew:
            parseHomebrewCleanupPreview(output: output, commandPreview: commandPreview)
        case .docker:
            parseDockerSystemDF(output: output, commandPreview: commandPreview)
        }
    }

    static func parseDockerSystemDFJSON(
        output: String,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let rows = try? JSONDecoder().decode([DockerSystemDFJSONRow].self, from: data) {
            return rows.compactMap { dockerJSONPreviewItem(from: $0, commandPreview: commandPreview) }
        }

        return trimmed.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let row = try? JSONDecoder().decode(DockerSystemDFJSONRow.self, from: data) else {
                return nil
            }
            return dockerJSONPreviewItem(from: row, commandPreview: commandPreview)
        }
    }

    static func parseDockerReclaimable(_ token: String) -> Int64? {
        let sizePart = token.split(separator: "(").first.map(String.init) ?? token
        return parseSize(sizePart)
    }

    static func parseFirstSize(in line: String) -> Int64? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*([KMGT]?B)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 3,
              let valueRange = Range(match.range(at: 1), in: line),
              let unitRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return parseSize("\(line[valueRange])\(line[unitRange])")
    }

    static func parseSize(_ token: String) -> Int64? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(\d+(?:\.\d+)?)\s*([KMGT]?B)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges == 3,
              let valueRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed),
              let value = Double(trimmed[valueRange]) else {
            return nil
        }

        let unit = trimmed[unitRange].uppercased()
        let multiplier: Double = switch unit {
        case "KB": 1_000
        case "MB": 1_000_000
        case "GB": 1_000_000_000
        case "TB": 1_000_000_000_000
        default: 1
        }

        let product = value * multiplier
        guard product.isFinite, product >= 0, product < Double(Int64.max) else {
            return nil
        }
        return Int64(product)
    }

    private static func parseHomebrewCleanupPreview(
        output: String,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        output.split(separator: "\n").enumerated().compactMap { index, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            guard line.lowercased().contains("would") || line.lowercased().contains("remove") else {
                return nil
            }

            return DeveloperToolPreviewItem(
                id: "homebrew-\(index)",
                tool: .homebrew,
                title: line,
                reclaimableBytes: parseFirstSize(in: line),
                commandPreview: commandPreview
            )
        }
    }

    private static func parseDockerSystemDF(
        output: String,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 5, fields[0] != "TYPE" else { return nil }
            guard let reclaimableIndex = fields.indices.last(where: { fields[$0].contains("B") }) else {
                return nil
            }
            let metricsStart = max(1, reclaimableIndex - 3)
            let type = fields[..<metricsStart].joined(separator: " ")
            return DeveloperToolPreviewItem(
                id: "docker-\(type.lowercased().replacingOccurrences(of: " ", with: "-"))",
                tool: .docker,
                title: type,
                detail: line,
                reclaimableBytes: parseDockerReclaimable(fields[reclaimableIndex]),
                commandPreview: commandPreview
            )
        }
    }

    private static func dockerJSONPreviewItem(
        from row: DockerSystemDFJSONRow,
        commandPreview: [String]
    ) -> DeveloperToolPreviewItem? {
        guard let type = row.value(for: "Type", "type"), !type.isEmpty else { return nil }
        let reclaimable = row.value(for: "Reclaimable", "reclaimable")
        let detail = [
            row.value(for: "Total", "TotalCount", "total", "totalCount").map { "Total: \($0)" },
            row.value(for: "Active", "active").map { "Active: \($0)" },
            row.value(for: "Size", "size").map { "Size: \($0)" },
            reclaimable.map { "Reclaimable: \($0)" },
        ]
        .compactMap(\.self)
        .joined(separator: " · ")

        return DeveloperToolPreviewItem(
            id: "docker-\(type.lowercased().replacingOccurrences(of: " ", with: "-"))",
            tool: .docker,
            title: type,
            detail: detail.isEmpty ? nil : detail,
            reclaimableBytes: reclaimable.flatMap(parseDockerReclaimable),
            commandPreview: commandPreview
        )
    }
}

private struct DockerSystemDFJSONRow: Decodable {
    let fields: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var fields: [String: String] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                fields[key.stringValue] = value
            } else if let value = try? container.decode(Int.self, forKey: key) {
                fields[key.stringValue] = String(value)
            } else if let value = try? container.decode(Double.self, forKey: key) {
                fields[key.stringValue] = String(value)
            }
        }
        self.fields = fields
    }

    func value(for names: String...) -> String? {
        for name in names {
            if let value = fields.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
