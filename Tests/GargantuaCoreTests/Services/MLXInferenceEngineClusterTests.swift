import Foundation
import Testing
@testable import GargantuaCore

private func makeClusterSummary(
    id: String = "~/Development/dreamheist/builds/",
    category: String = "Broken / Corrupt",
    count: Int = 847,
    totalSize: Int64 = 1_200_000_000,
    samplePaths: [String] = [
        "/Users/jason/Development/dreamheist/builds/session-aaa/foo.png",
        "/Users/jason/Development/dreamheist/builds/session-bbb/bar.png",
    ]
) -> FileHealthClusterSummary {
    FileHealthClusterSummary(
        id: id,
        category: category,
        count: count,
        totalSize: totalSize,
        samplePaths: samplePaths
    )
}

@Suite("MLXInferenceEngine cluster suggestion prompt and parser")
@MainActor
struct MLXInferenceEngineClusterTests {

    // MARK: - Cluster suggestion prompt

    @Test("Cluster prompt includes id, category, count, size, and samples")
    func clusterPromptShape() {
        let prompt = MLXInferenceEngine.buildClusterSuggestionPrompt(for: [makeClusterSummary()])

        #expect(prompt.contains("~/Development/dreamheist/builds/"))
        #expect(prompt.contains("Broken / Corrupt"))
        #expect(prompt.contains("847"))
        #expect(prompt.contains("session-aaa"))
        #expect(prompt.contains("\"suggestions\""), "Prompt instructs the model to use the JSON shape we parse")
    }

    @Test("Cluster prompt caps sample paths at five so prompt stays bounded")
    func clusterPromptCapsSamples() {
        let many = (0 ..< 20).map { "/Users/jason/x/\($0)/file.png" }
        let summary = makeClusterSummary(samplePaths: many)
        let prompt = MLXInferenceEngine.buildClusterSuggestionPrompt(for: [summary])

        // First five paths should appear, the sixth should not.
        for idx in 0 ..< 5 {
            #expect(prompt.contains("/Users/jason/x/\(idx)/file.png"))
        }
        #expect(!prompt.contains("/Users/jason/x/5/file.png"))
    }

    // MARK: - Cluster JSON parser

    @Test("Cluster JSON parser accepts well-formed responses")
    func clusterParserHappyPath() {
        let summary = makeClusterSummary()
        let response = """
        {"suggestions":[{"cluster_id":"~/Development/dreamheist/builds/",\
        "label":"Build session detritus","safety":"safe",\
        "rationale":"Regenerable build output."}]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].clusterID == summary.id)
        #expect(suggestions[0].label == "Build session detritus")
        #expect(suggestions[0].safety == .safe)
        #expect(suggestions[0].rationale == "Regenerable build output.")
    }

    @Test("Cluster JSON parser tolerates leading prose and markdown fences")
    func clusterParserTolerantWrapping() {
        let summary = makeClusterSummary()
        let response = """
        Sure — here are the suggestions you asked for:
        ```json
        {"suggestions":[{"cluster_id":"~/Development/dreamheist/builds/","label":"Builds","safety":"safe","rationale":"Reproducible."}]}
        ```
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].label == "Builds")
    }

    @Test("Cluster JSON parser drops entries that don't reference a known cluster id")
    func clusterParserDropsUnknownIDs() {
        let summary = makeClusterSummary()
        let response = """
        {"suggestions":[
          {"cluster_id":"~/Development/dreamheist/builds/","label":"Real","safety":"safe","rationale":""},
          {"cluster_id":"/etc/secret/","label":"Hallucinated","safety":"safe","rationale":""}
        ]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].clusterID == summary.id)
    }

    @Test("Cluster JSON parser drops entries with unrecognized safety values")
    func clusterParserDropsBadSafety() {
        let summary = makeClusterSummary()
        let response = """
        {"suggestions":[{"cluster_id":"~/Development/dreamheist/builds/","label":"X","safety":"yolo","rationale":""}]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.isEmpty)
    }

    @Test("Cluster JSON parser is empty on malformed input")
    func clusterParserEmptyOnMalformed() {
        let summary = makeClusterSummary()
        let nonsense = "the model just chatted at me without any JSON"
        #expect(MLXInferenceEngine.parseClusterSuggestions(nonsense, allowed: [summary]).isEmpty)
    }

    @Test("Cluster JSON parser tolerates missing trailing slash on cluster id")
    func clusterParserTolerantOfTrailingSlash() {
        let summary = makeClusterSummary()
        let response = """
        {"suggestions":[{"cluster_id":"~/Development/dreamheist/builds","label":"Build detritus","safety":"safe","rationale":""}]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        // The canonical id (with trailing slash) should be returned even if
        // the model omitted it.
        #expect(suggestions[0].clusterID == summary.id)
    }

    @Test("Cluster JSON parser tolerates expanded home path instead of ~/")
    func clusterParserTolerantOfExpandedHome() {
        let summary = makeClusterSummary()
        let home = NSString(string: "~").expandingTildeInPath
        let response = """
        {"suggestions":[{"cluster_id":"\(home)/Development/dreamheist/builds/","label":"Build","safety":"safe","rationale":""}]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        // Canonical ~/-form is returned; UI uses that key downstream.
        #expect(suggestions[0].clusterID == summary.id)
    }

    @Test("Cluster JSON parser tolerates case differences in cluster id")
    func clusterParserTolerantOfCase() {
        let summary = makeClusterSummary()
        let response = """
        {"suggestions":[{"cluster_id":"~/development/DREAMHEIST/builds/","label":"X","safety":"safe","rationale":""}]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].clusterID == summary.id)
    }

    @Test("Cluster JSON parser accepts a bare top-level array shape")
    func clusterParserBareArray() {
        let summary = makeClusterSummary()
        let response = """
        [{"cluster_id":"~/Development/dreamheist/builds/","label":"X","safety":"review","rationale":"y"}]
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].safety == .review)
    }

    @Test("Cluster JSON parser deduplicates by cluster id")
    func clusterParserDeduplicates() {
        let summary = makeClusterSummary()
        let response = """
        {"suggestions":[
          {"cluster_id":"~/Development/dreamheist/builds/","label":"First","safety":"safe","rationale":""},
          {"cluster_id":"~/Development/dreamheist/builds/","label":"Second","safety":"review","rationale":""}
        ]}
        """
        let suggestions = MLXInferenceEngine.parseClusterSuggestions(response, allowed: [summary])

        #expect(suggestions.count == 1)
        #expect(suggestions[0].label == "First")
    }
}
