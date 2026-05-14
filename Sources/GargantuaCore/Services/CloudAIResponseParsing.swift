import Foundation

struct DeepAnalysisPayload: Decodable {
    let summary: String
    let recommendations: [String]
}

struct TargetCleanupPayload: Decodable {
    let itemIDs: [String]
    let rationale: String

    enum CodingKeys: String, CodingKey {
        case itemIDs = "item_ids"
        case rationale
    }
}

struct DuplicateResolutionPayload: Decodable {
    let suggestions: [DuplicateResolutionSuggestionPayload]
}

struct DuplicateResolutionSuggestionPayload: Decodable {
    let groupID: String
    let keepID: String
    let deleteIDs: [String]
    let rationale: String

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case keepID = "keep_id"
        case deleteIDs = "delete_ids"
        case rationale
    }
}

struct ScanRuleSuggestionPayload: Decodable {
    let yaml: String
    let rationale: String
}

struct OrganizerProposalPayload: Decodable {
    let plans: [OrganizerProposalPlanPayload]
}

struct OrganizerProposalPlanPayload: Decodable {
    let clusterID: String
    let name: String
    let reasoning: String

    enum CodingKeys: String, CodingKey {
        case clusterID = "cluster_id"
        case name
        case reasoning
    }
}

enum CloudAIJSONExtractor {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = firstJSONObjectData(in: text) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func firstJSONObjectData(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return Data(text[start ..< end].utf8)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
