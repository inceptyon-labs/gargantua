import Foundation

/// Locates the `czkawka_cli` binary for the Czkawka scan adapter.
///
/// Resolution order:
/// 1. `GARGANTUA_CZKAWKA_BIN` environment variable (explicit override)
/// 2. Any of the common install locations on `PATH`
/// 3. A binary bundled alongside the app under `Contents/Resources/czkawka_cli`
public struct CzkawkaBinaryResolver: Sendable {
    public enum ResolutionError: Error, LocalizedError, Sendable, Equatable {
        case notFound
        case notExecutable(path: String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                "czkawka_cli not found. Install it (e.g., `brew install czkawka`) or set GARGANTUA_CZKAWKA_BIN."
            case .notExecutable(let path):
                "czkawka_cli at \(path) is not executable."
            }
        }
    }

    public static let envVarName = "GARGANTUA_CZKAWKA_BIN"

    /// Common install locations checked when the binary isn't already on the
    /// search path surfaced to a non-login shell.
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/czkawka_cli",
        "/usr/local/bin/czkawka_cli",
        "/usr/bin/czkawka_cli",
    ]

    private let environment: [String: String]
    private let bundledURL: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledURL: URL? = Bundle.main.url(forResource: "czkawka_cli", withExtension: nil)
    ) {
        self.environment = environment
        self.bundledURL = bundledURL
    }

    /// Resolve the path to czkawka_cli, or throw `.notFound`.
    public func resolve() throws -> URL {
        let fileManager = FileManager.default

        if let override = environment[Self.envVarName], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw ResolutionError.notFound
            }
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw ResolutionError.notExecutable(path: url.path)
            }
            return url
        }

        for candidate in Self.candidatePaths
        where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        if let bundled = bundledURL, fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        throw ResolutionError.notFound
    }

    /// Whether czkawka_cli is available without requiring the caller to catch an error.
    public func isAvailable() -> Bool {
        (try? resolve()) != nil
    }
}
