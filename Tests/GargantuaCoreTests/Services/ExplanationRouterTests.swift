import Foundation
import Testing
@testable import GargantuaCore

@Suite("ExplanationRouter")
@MainActor
struct ExplanationRouterTests {
    private func makeResult() -> ScanResult {
        ScanResult(
            id: "r1",
            name: "Cache",
            path: "/tmp/cache",
            size: 1024,
            safety: .safe,
            confidence: 90,
            explanation: "Regenerated.",
            source: SourceAttribution(name: "App", bundleID: "com.example"),
            category: "cache",
            tags: [],
            regenerates: true
        )
    }

    @Test("A local assignment dispatches to the local service")
    func localDispatch() async throws {
        let local = RouterStubService(text: "local answer")
        let router = ExplanationRouter(
            local: local,
            cloud: CloudAIService(),
            assignment: { _ in .template }
        )

        let result = makeResult()
        let explanation = try await router.explain(
            .inlineExplain,
            result: result,
            rule: AIExplanationController.derivedRule(from: result)
        )

        #expect(explanation.text == "local answer")
        #expect(local.callCount == 1)
    }

    @Test("Local engines are always available; an unconfigured Cloud is not")
    func availability() {
        let local = RouterStubService(text: "x")
        let cloudRouter = ExplanationRouter(local: local, cloud: CloudAIService(), assignment: { _ in .cloud })
        let localRouter = ExplanationRouter(local: local, cloud: CloudAIService(), assignment: { _ in .mlx })

        #expect(localRouter.isAvailable(.inlineExplain))
        // A freshly-constructed CloudAIService is disabled with no key.
        #expect(!cloudRouter.isAvailable(.deeperExplain))
    }
}

@MainActor
private final class RouterStubService: AIServiceProtocol {
    var isModelAvailable = true
    private(set) var callCount = 0
    private let text: String

    init(text: String) { self.text = text }

    func explain(result _: ScanResult, rule _: ScanRule) async throws -> AIExplanation {
        callCount += 1
        return AIExplanation(text: text, source: .ai)
    }
}
