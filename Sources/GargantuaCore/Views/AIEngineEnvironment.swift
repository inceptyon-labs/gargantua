import SwiftUI

/// SwiftUI environment hooks the AI honesty pass uses to make UI choices
/// without threading service references through every scan view.
///
/// - `activeAIEngineKind` lets per-row affordances (e.g. `DenseScanItemRow`'s
///   hover glyph) swap based on whether the user has local AI on.
/// - `aiEngineNeedsFirstWarmup` lets loading spinners surface a one-time
///   "Compiling shaders for first use…" subtitle while MLX JIT-compiles its
///   kernels on the first inference of a session.
/// - `openAIModelSettings` lets sheets show an "Enable AI" CTA that deep-links
///   into the AI Model section of Settings.

private struct ActiveAIEngineKindKey: EnvironmentKey {
    static let defaultValue: AIEnginePreference = .template
}

private struct PreferredAIEngineKindKey: EnvironmentKey {
    static let defaultValue: AIEnginePreference = .template
}

private struct AIEngineNeedsFirstWarmupKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct OpenAIModelSettingsKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

public extension EnvironmentValues {
    /// Currently *running* local AI engine. May differ from
    /// `preferredAIEngineKind` when the user picked MLX but the model isn't
    /// downloaded — `AIInferenceEngineFactory` falls back to Template, so
    /// per-row glyphs and source labels honestly reflect rule-based output.
    var activeAIEngineKind: AIEnginePreference {
        get { self[ActiveAIEngineKindKey.self] }
        set { self[ActiveAIEngineKindKey.self] = newValue }
    }

    /// What the user actually picked in Settings (the toggle state). The CTA
    /// branches on this: `.template` → "Enable AI" (user has AI off);
    /// `.mlx` while the active engine fell back to Template → "Download
    /// Model" (user has AI on, just stuck on the fallback).
    var preferredAIEngineKind: AIEnginePreference {
        get { self[PreferredAIEngineKindKey.self] }
        set { self[PreferredAIEngineKindKey.self] = newValue }
    }

    /// True iff MLX is the active engine and it has not yet completed an
    /// inference in this session. The first call after launch JIT-compiles
    /// ~30 GPU kernels; cold-cache cost is 20–30 s and the spinner can
    /// otherwise look hung. After the first response, this stays false until
    /// the engine is reconfigured.
    var aiEngineNeedsFirstWarmup: Bool {
        get { self[AIEngineNeedsFirstWarmupKey.self] }
        set { self[AIEngineNeedsFirstWarmupKey.self] = newValue }
    }

    /// Optional deep-link into the AI Model section of Settings. Used by
    /// sheets and the cleanup summary to render an "Enable AI" CTA when the
    /// rendered text is rule-based and the user might want generated output.
    var openAIModelSettings: (() -> Void)? {
        get { self[OpenAIModelSettingsKey.self] }
        set { self[OpenAIModelSettingsKey.self] = newValue }
    }
}
