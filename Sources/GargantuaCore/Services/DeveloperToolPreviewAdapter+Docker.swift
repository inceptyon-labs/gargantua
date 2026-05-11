import Foundation

extension DeveloperToolPreviewAdapter {
    func dockerPreview(executable: URL) throws -> DeveloperToolPreview {
        let structuredArguments = Self.structuredPreviewArguments(for: .docker)
        let structuredOutput = try runDockerPreviewCommand(
            executable: executable,
            arguments: structuredArguments
        )

        if structuredOutput.exitCode == 0 {
            let rawOutput = structuredOutput.stdout.isEmpty ? structuredOutput.stderr : structuredOutput.stdout
            let commandPreview = [executable.path] + structuredArguments
            let items = Self.parseDockerSystemDFJSON(output: rawOutput, commandPreview: commandPreview)
            if !items.isEmpty {
                return DeveloperToolPreview(
                    tool: .docker,
                    commandPreview: commandPreview,
                    items: items,
                    rawOutput: rawOutput
                )
            }
        } else {
            let stderr = structuredOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: stderr) {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
        }

        return try legacyDockerPreview(executable: executable)
    }

    func legacyDockerPreview(executable: URL) throws -> DeveloperToolPreview {
        let arguments = Self.previewArguments(for: .docker)
        let output = try runDockerPreviewCommand(
            executable: executable,
            arguments: arguments
        )
        guard output.exitCode == 0 else {
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: stderr) {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
            throw DeveloperToolPreviewError.commandFailed(
                tool: .docker,
                exitCode: output.exitCode,
                stderr: stderr
            )
        }

        let rawOutput = output.stdout.isEmpty ? output.stderr : output.stdout
        let commandPreview = [executable.path] + arguments
        return DeveloperToolPreview(
            tool: .docker,
            commandPreview: commandPreview,
            items: Self.parsePreview(tool: .docker, commandPreview: commandPreview, output: rawOutput),
            rawOutput: rawOutput
        )
    }

    func runDockerPreviewCommand(
        executable: URL,
        arguments: [String]
    ) throws -> ProcessOutput {
        do {
            return try runner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
            )
        } catch {
            if let runnerError = error as? ProcessRunnerError,
               case .timedOut = runnerError {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
            throw error
        }
    }
}
