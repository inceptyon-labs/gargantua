import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.app", category: "MetallibStager")

/// Stages `mlx.metallib` next to the running binary so mlx-swift's loader
/// (`load_colocated_library` in mlx/backend/metal/device.cpp) can find it.
///
/// `swift run Gargantua` puts the binary at `.build/<arch>/<config>/Gargantua`
/// but the metallib produced by `BuildMetallibPlugin` lands inside the target's
/// resource bundle at `<bin-dir>/Gargantua_Gargantua.bundle/Contents/Resources/`.
/// MLX's first-priority lookup is colocated with the binary, so we copy it
/// once at startup. Production `.app` builds already stage the metallib via
/// `Scripts/release/assemble-app.sh`, so the copy is a no-op there.
///
/// Safe to call repeatedly; later calls are no-ops once the colocated file
/// exists. Failures are logged but do not throw — the inference layer falls
/// back to the template engine when MLX is unavailable.
enum MetallibStager {
    static func stageIfNeeded() {
        guard let executableURL = Bundle.main.executableURL else {
            logger.warning("Bundle.main.executableURL is nil — skipping metallib staging")
            return
        }

        let binaryDir = executableURL.deletingLastPathComponent()
        let target = binaryDir.appendingPathComponent("mlx.metallib")

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            return
        }

        guard let source = Bundle.module.url(forResource: "mlx", withExtension: "metallib") else {
            // Plugin didn't produce the artifact — likely Metal toolchain
            // missing at build time. MLXInferenceEngine.load will surface a
            // catchable error and the AI service falls back to the template.
            logger.warning("mlx.metallib not present in bundle resources — MLX paths will fall back")
            return
        }

        do {
            try fm.copyItem(at: source, to: target)
            logger.info("Staged mlx.metallib at \(target.path, privacy: .public)")
        } catch {
            logger.warning("Failed to stage mlx.metallib: \(error.localizedDescription, privacy: .public)")
        }
    }
}
