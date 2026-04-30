import Foundation
import Testing
@testable import GargantuaCore

/// Pin the user-facing copy on the Agent Run help surface. The five example
/// prompts are drawn verbatim from gargantua-ryfq's empirical test, and the
/// disclaimer copy was negotiated with the user — accidental copy edits would
/// silently undermine the "ship before the small fix to set expectations"
/// goal of gargantua-4583.
@Suite("Agent Run help content")
struct ClaudeCodeAgentHelpContentTests {

    @Test("Disclaimer keeps the situational vs routine framing")
    func disclaimerFraming() {
        #expect(ClaudeCodeAgentHelpContent.disclaimerLeadIn == "Agent Run is for situational questions")
        #expect(ClaudeCodeAgentHelpContent.disclaimerFallback == "For routine cleanup, run Deep Scan instead")

        // Make sure the detail clauses actually name the situations the agent
        // is good at — if someone shortens this to a generic blurb, the
        // disclaimer stops doing its job.
        let detail = ClaudeCodeAgentHelpContent.disclaimerLeadInDetail
        #expect(detail.contains("pre-upgrade triage"))
        #expect(detail.contains("orphan-cache"))
        #expect(detail.contains("version cleanup"))
    }

    @Test("All five empirical-test example prompts ship in the help sheet")
    func examplePromptsArePresent() {
        let prompts = ClaudeCodeAgentHelpContent.examplePrompts
        #expect(prompts.count == 5, "All 5 example prompts from the empirical test must be present")

        let useCases = Set(prompts.map(\.useCase))
        #expect(useCases.contains("Pre-event triage"))
        #expect(useCases.contains("Orphan / dead-app cache hunting"))
        #expect(useCases.contains("Version cleanup"))
        #expect(useCases.contains("Criterion filtering"))
        #expect(useCases.contains("Project archaeology"))
    }

    @Test("Example prompts retain identifying phrases from the empirical test")
    func examplePromptsKeepKeyPhrases() {
        // Spot-check distinguishing phrases rather than full strings so a
        // typographic edit (curly quotes, em-dash) doesn't fail the test, but
        // a meaning-changing edit will.
        let prompts = ClaudeCodeAgentHelpContent.examplePrompts.map(\.prompt)

        #expect(prompts.contains { $0.contains("macOS upgrade tomorrow") })
        #expect(prompts.contains { $0.contains("caches that are safe to delete") })
        #expect(prompts.contains { $0.contains("multiple versions") })
        #expect(prompts.contains { $0.contains("haven") && $0.contains("6+ months") })
        #expect(prompts.contains { $0.contains("~/Development") })
    }

    @Test("Each example prompt has a non-empty use case and prompt body")
    func examplePromptsAreNonEmpty() {
        for example in ClaudeCodeAgentHelpContent.examplePrompts {
            #expect(!example.useCase.isEmpty)
            #expect(!example.prompt.isEmpty)
            #expect(!example.id.isEmpty)
        }
    }

    @Test("Example prompt IDs are unique so SwiftUI ForEach is stable")
    func examplePromptIdsAreUnique() {
        let ids = ClaudeCodeAgentHelpContent.examplePrompts.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Deep Scan guidance lists the three main routine cases")
    func deepScanGuidance() {
        let lines = ClaudeCodeAgentHelpContent.whenToUseDeepScan
        #expect(lines.count == 3)
        #expect(lines.contains { $0.lowercased().contains("clean all") })
        #expect(lines.contains { $0.lowercased().contains("most space") })
        #expect(lines.contains { $0.lowercased().contains("weekly") })
    }

    // MARK: - Try-this-prompt chips

    @Test("Every preset surfaces at least one try-this-prompt chip")
    func everyPresetHasChips() {
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let chips = ClaudeCodeAgentHelpContent.chips(for: template)
            #expect(!chips.isEmpty, "preset \(template.rawValue) should have ≥1 chip")
        }
    }

    @Test("Every chip ID resolves to an existing example prompt")
    func chipIDsResolveToExamplePrompts() {
        let knownIDs = Set(ClaudeCodeAgentHelpContent.examplePrompts.map(\.id))
        for (template, ids) in ClaudeCodeAgentHelpContent.chipsByTemplate {
            for id in ids {
                #expect(knownIDs.contains(id), "preset \(template.rawValue) references unknown prompt ID '\(id)'")
            }
        }
    }

    @Test("Chip labels are short topic phrases, not full prompts")
    func chipLabelsAreShortTopics() {
        for example in ClaudeCodeAgentHelpContent.examplePrompts {
            #expect(!example.chipLabel.isEmpty, "prompt \(example.id) has empty chipLabel")
            #expect(example.chipLabel.count <= 24, "chipLabel '\(example.chipLabel)' (\(example.chipLabel.count) chars) exceeds 24-char budget")
        }
    }

    @Test("Chip mapping covers every prompt template case")
    func chipMappingIsExhaustive() {
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            #expect(
                ClaudeCodeAgentHelpContent.chipsByTemplate[template] != nil,
                "preset \(template.rawValue) is missing from chipsByTemplate"
            )
        }
    }

    @Test("chips(for:) returns prompts in mapping order")
    func chipsPreserveMappingOrder() {
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let expectedIDs = ClaudeCodeAgentHelpContent.chipsByTemplate[template] ?? []
            let resolvedIDs = ClaudeCodeAgentHelpContent.chips(for: template).map(\.id)
            #expect(resolvedIDs == expectedIDs, "preset \(template.rawValue) chip order drifted")
        }
    }
}
