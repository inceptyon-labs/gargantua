import Foundation

extension LocalAIService {
    public func explain(result: ScanResult, rule: ScanRule) async throws -> AIExplanation {
        // Capture the engine + its source label up front. A settings change
        // mid-call (`configureEngine`) replaces `self.engine`, but inference
        // already in flight should be labeled and accounted against the
        // engine that actually produced it.
        let engine = self.engine
        let stampingSource = sourceForKind(engine.kind)

        // Template engine doesn't need model weights — it stitches rule +
        // scan metadata. Run it directly so "AI Off" produces honest
        // `.template` output instead of falling back to raw YAML.
        if engine.kind == .template {
            do {
                let text = try await engine.generate(for: result, rule: rule)
                return AIExplanation(text: text, source: stampingSource)
            } catch {
                return AIExplanation(text: rule.explanation, source: .rule)
            }
        }

        // MLX path: needs a downloaded model, lazy-load + ready guards apply.
        guard isModelAvailable else {
            return AIExplanation(text: rule.explanation, source: .rule)
        }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return AIExplanation(text: rule.explanation, source: .rule)
            }
        }

        guard lifecycleState == .ready else {
            return AIExplanation(text: rule.explanation, source: .rule)
        }

        // Suspend the idle timer while inference is in flight so a long
        // generation on a real MLX backend cannot be unloaded mid-call.
        // The timer is restarted once no inference is active.
        idleTask?.cancel()
        idleTask = nil
        activeInferenceCount += 1
        defer {
            activeInferenceCount -= 1
            if activeInferenceCount == 0 && lifecycleState == .ready {
                resetIdleTimer()
            }
        }

        do {
            let text = try await engine.generate(for: result, rule: rule)
            markFirstInferenceComplete(for: engine.kind)
            return AIExplanation(text: text, source: stampingSource)
        } catch {
            return AIExplanation(text: rule.explanation, source: .rule)
        }
    }
}
