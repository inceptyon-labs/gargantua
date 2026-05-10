import Foundation
import PackagePlugin

/// SwiftPM build tool plugin that compiles mlx-swift's Metal shader sources
/// into `mlx.metallib` and registers it as a resource of the host target.
///
/// `swift run Gargantua` and `swift test` skip Metal compilation by themselves
/// — Xcode's build system owns `.metal → .air → .metallib`, and SPM has no
/// equivalent. Without a metallib, the first MLX kernel call aborts in C++
/// (un-catchable from Swift), killing the whole process. The release pipeline
/// stages the artifact via Scripts/release/assemble-app.sh; this plugin fills
/// in the gap for the SPM CLI.
///
/// The plugin shells out to `scripts/build-metallib.sh`, which already knows
/// how to find the mlx-swift checkout, run xcrun metal/metallib, and link the
/// result. Output lands in the plugin work directory; SPM picks it up as a
/// resource of the target the plugin is attached to. The host target then
/// copies the metallib next to the running binary at launch (where mlx-swift's
/// `load_colocated_library` looks first).
@main
struct BuildMetallibPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let script = context.package.directory
            .appending(subpath: "scripts")
            .appending(subpath: "build-metallib.sh")

        let outputDir = context.pluginWorkDirectory
        let metallib = outputDir.appending(subpath: "mlx.metallib")

        return [
            .prebuildCommand(
                displayName: "Compile mlx.metallib",
                executable: Path("/bin/bash"),
                arguments: [script.string, "--output", metallib.string],
                outputFilesDirectory: outputDir
            ),
        ]
    }
}
