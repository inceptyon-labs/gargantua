import Testing
import Foundation
@testable import GargantuaCore

@MainActor
@Suite("MLXOrganizerProposer lenient parser")
struct MLXOrganizerProposerTests {

    // MARK: - extractJSON

    @Test("Plain JSON object passes through unchanged")
    func plainObject() {
        let raw = #"{"plans":[{"name":"X","reasoning":"","item_ids":["a","b"]}]}"#
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out == raw)
    }

    @Test("JSON wrapped in ```json fences is unwrapped")
    func fenceJSONLanguage() {
        let raw = """
        ```json
        {"plans":[{"name":"X","reasoning":"","item_ids":["a"]}]}
        ```
        """
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out?.contains("\"plans\"") == true)
        #expect(out?.contains("```") == false)
    }

    @Test("JSON wrapped in plain ``` fences is unwrapped")
    func fencePlain() {
        let raw = """
        ```
        {"plans":[{"name":"X","reasoning":"","item_ids":["a"]}]}
        ```
        """
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out?.contains("\"plans\"") == true)
        #expect(out?.contains("```") == false)
    }

    @Test("Leading prose before the JSON is stripped")
    func leadingProse() {
        let raw = "Sure! Here are the groupings:\n\n{\"plans\":[]}"
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out == "{\"plans\":[]}")
    }

    @Test("Trailing prose after the JSON is stripped")
    func trailingProse() {
        let raw = #"{"plans":[]} Let me know if you want me to refine this!"#
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out == "{\"plans\":[]}")
    }

    @Test("Bare top-level array is rewrapped as {\"plans\":[...]}")
    func bareArrayWrapped() {
        let raw = #"[{"name":"X","reasoning":"","item_ids":["a"]}]"#
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out == #"{"plans":[{"name":"X","reasoning":"","item_ids":["a"]}]}"#)
    }

    @Test("Garbage with no braces or brackets returns nil")
    func garbageReturnsNil() {
        let raw = "I don't know how to organize these files."
        #expect(MLXOrganizerProposer.extractJSON(from: raw) == nil)
    }

    @Test("Quoted braces inside strings don't fool the depth counter")
    func quotedBracesIgnored() {
        let raw = #"{"plans":[{"name":"folder { with brace }","reasoning":"x","item_ids":["a"]}]}"#
        let out = MLXOrganizerProposer.extractJSON(from: raw)
        #expect(out == raw)
    }

    // MARK: - prompt builder

    @Test("Prompt includes the worked example and the user's listing")
    func promptHasExampleAndItems() {
        let items = [
            CloudOrganizerProposer.FolderListingItem(
                id: "X-1",
                url: URL(fileURLWithPath: "/tmp/alpha.pdf"),
                name: "alpha.pdf",
                sizeBytes: 100,
                modifiedAt: Date()
            ),
            CloudOrganizerProposer.FolderListingItem(
                id: "X-2",
                url: URL(fileURLWithPath: "/tmp/beta.pdf"),
                name: "beta.pdf",
                sizeBytes: 200,
                modifiedAt: Date()
            ),
        ]
        let prompt = MLXOrganizerProposer.buildSmallModelPrompt(
            folderName: "Downloads",
            items: items
        )
        #expect(prompt.contains("ExampleFolder"))
        #expect(prompt.contains("receipt-jan.pdf"))
        #expect(prompt.contains("Folder: Downloads"))
        #expect(prompt.contains("X-1: alpha.pdf"))
        #expect(prompt.contains("X-2: beta.pdf"))
    }
}
