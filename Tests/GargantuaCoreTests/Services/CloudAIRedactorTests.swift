import Foundation
import Testing

@testable import GargantuaCore

@Suite("CloudAIRedactor")
struct CloudAIRedactorTests {

    // MARK: - sanitizeContent

    @Test("Empty string sanitizes to empty string")
    func sanitizeEmpty() {
        #expect(CloudAIRedactor.sanitizeContent("") == "")
    }

    @Test("Whitespace-only string sanitizes to empty (trimmed)")
    func sanitizeWhitespaceOnly() {
        #expect(CloudAIRedactor.sanitizeContent("   \t\n  ") == "")
    }

    @Test("Multiple internal whitespace runs collapse to a single space")
    func sanitizeCollapsesWhitespace() {
        #expect(CloudAIRedactor.sanitizeContent("a  \t  b\n\nc") == "a b c")
    }

    @Test("Surrounding whitespace is trimmed")
    func sanitizeTrimsEdges() {
        #expect(CloudAIRedactor.sanitizeContent("  hello  ") == "hello")
    }

    @Test("Control characters other than tab/newline are replaced with spaces")
    func sanitizeStripsControlChars() {
        // \u{07} BEL, \u{1B} ESC, \u{00} NUL — all should become spaces and
        // then collapse with surrounding whitespace.
        let input = "a\u{07}b\u{1B}c\u{00}d"
        #expect(CloudAIRedactor.sanitizeContent(input) == "a b c d")
    }

    @Test("Tabs and newlines are preserved as whitespace and collapsed")
    func sanitizePreservesTabAndNewline() {
        #expect(CloudAIRedactor.sanitizeContent("a\tb\nc") == "a b c")
    }

    @Test("Inputs longer than 4000 chars are truncated")
    func sanitizeTruncates() {
        let raw = String(repeating: "x", count: 5_000)
        let out = CloudAIRedactor.sanitizeContent(raw)
        #expect(out.count == CloudAIRedactor.maxContentPreviewCharacters)
        #expect(out.count == 4_000)
    }

    @Test("Inputs at the truncation boundary are unchanged")
    func sanitizeBoundary() {
        let raw = String(repeating: "y", count: CloudAIRedactor.maxContentPreviewCharacters)
        #expect(CloudAIRedactor.sanitizeContent(raw).count == CloudAIRedactor.maxContentPreviewCharacters)
    }

    // MARK: - items()

    @Test("items() omits content preview when allowsFileContents is false")
    func itemsOmitsPreviewWithoutConsent() throws {
        let result = makeResult(id: "a")
        let items = try CloudAIRedactor.items(
            from: [result],
            allowsFileContents: false,
            contentProvider: { _ in "should be ignored" }
        )
        #expect(items.count == 1)
        #expect(items[0].contentPreview == nil)
    }

    @Test("items() includes sanitized preview when consent granted and provider supplied")
    func itemsIncludesPreviewWithConsent() throws {
        let result = makeResult(id: "b")
        let items = try CloudAIRedactor.items(
            from: [result],
            allowsFileContents: true,
            contentProvider: { _ in "  raw\u{07}  content  " }
        )
        #expect(items.count == 1)
        #expect(items[0].contentPreview == "raw content")
    }

    @Test("items() applies sanitizeContent to name, explanation, sourceName, tags")
    func itemsSanitizesStringFields() throws {
        let raw = ScanResult(
            id: "c",
            name: "  noisy\u{07}name  ",
            path: "/Users/test/Library/Caches/c",
            size: 100,
            safety: .safe,
            confidence: 90,
            explanation: "exp\nwith\twhitespace",
            source: SourceAttribution(name: "Source\u{1B}Name", bundleID: nil),
            lastAccessed: nil,
            category: "test_cache",
            tags: ["  tag\u{07}one  "],
            regenerates: false,
            regenerateCommand: "  cmd\u{07}arg  "
        )
        let items = try CloudAIRedactor.items(from: [raw], allowsFileContents: false)
        #expect(items[0].name == "noisy name")
        #expect(items[0].explanation == "exp with whitespace")
        #expect(items[0].sourceName == "Source Name")
        #expect(items[0].tags == ["tag one"])
        #expect(items[0].regenerateCommand == "cmd arg")
    }

    @Test("items() preserves path verbatim — not run through sanitizeContent")
    func itemsKeepsPathVerbatim() throws {
        let result = makeResult(id: "d", path: "/Users/jason/Library/Caches/foo bar/file.txt")
        let items = try CloudAIRedactor.items(from: [result], allowsFileContents: false)
        #expect(items[0].path == "/Users/jason/Library/Caches/foo bar/file.txt")
    }

    @Test("items() preserves count and order")
    func itemsPreservesCountAndOrder() throws {
        let inputs = (0..<5).map { makeResult(id: "id-\($0)") }
        let items = try CloudAIRedactor.items(from: inputs, allowsFileContents: false)
        #expect(items.count == 5)
        #expect(items.map(\.id) == ["id-0", "id-1", "id-2", "id-3", "id-4"])
    }

    @Test("items() propagates errors thrown by the content provider")
    func itemsPropagatesProviderErrors() {
        let result = makeResult(id: "e")
        struct ProviderFailure: Error {}
        #expect(throws: ProviderFailure.self) {
            try CloudAIRedactor.items(
                from: [result],
                allowsFileContents: true,
                contentProvider: { _ in throw ProviderFailure() }
            )
        }
    }

    // MARK: - CloudAIPromptBuilder

    @Test("deepAnalysisPrompt embeds the JSON payload and the schema instruction")
    func deepAnalysisPromptShape() throws {
        let items = try CloudAIRedactor.items(from: [makeResult(id: "a")], allowsFileContents: false)
        let prompt = try CloudAIPromptBuilder.deepAnalysisPrompt(items: items)
        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("\"recommendations\""))
        #expect(prompt.contains("\"id\":\"a\""))
    }

    @Test("targetCleanupPrompt includes the byte target verbatim")
    func targetCleanupPromptIncludesBytes() throws {
        let items = try CloudAIRedactor.items(from: [makeResult(id: "a")], allowsFileContents: false)
        let prompt = try CloudAIPromptBuilder.targetCleanupPrompt(items: items, targetBytes: 1_024_000)
        #expect(prompt.contains("1024000"))
        #expect(prompt.contains("safety"))
        #expect(prompt.contains("Exclude protected items"))
    }

    @Test("scanRuleSuggestionPrompt requests YAML and notes proposed-rules guard")
    func scanRuleSuggestionPromptShape() throws {
        let items = try CloudAIRedactor.items(from: [makeResult(id: "a")], allowsFileContents: false)
        let prompt = try CloudAIPromptBuilder.scanRuleSuggestionPrompt(items: items)
        #expect(prompt.contains("yaml"))
        #expect(prompt.contains("proposed-rules"))
    }

    @Test("System prompt forbids overriding YAML safety classifications")
    func systemPromptSafetyPin() {
        #expect(CloudAIPromptBuilder.systemPrompt.contains("never override YAML safety"))
        #expect(CloudAIPromptBuilder.systemPrompt.contains("never mark protected items"))
    }

    // MARK: - Fixtures

    private func makeResult(
        id: String,
        path: String? = nil,
        safety: SafetyLevel = .safe,
        size: Int64 = 512
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Item \(id)",
            path: path ?? "/Users/test/Library/Caches/\(id)",
            size: size,
            safety: safety,
            confidence: 91,
            explanation: "Generated test item.",
            source: SourceAttribution(name: "Example", bundleID: "com.example.app"),
            lastAccessed: Date(timeIntervalSince1970: 1_700_000_000),
            category: "test_cache",
            tags: [],
            regenerates: true,
            regenerateCommand: "example --rebuild"
        )
    }
}
