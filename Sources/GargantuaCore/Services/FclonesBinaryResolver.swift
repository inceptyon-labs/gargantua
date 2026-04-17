import Foundation

/// Locates the `fclones` binary for the Duplicate Finder scan adapter.
///
/// Resolution order:
/// 1. `GARGANTUA_FCLONES_BIN` environment variable (explicit override)
/// 2. Any of the common install locations on `PATH`
/// 3. A binary bundled alongside the app under `Contents/Resources/fclones`
public struct FclonesBinaryResolver: Sendable {
    public enum ResolutionError: Error, LocalizedError, Sendable, Equatable {
        case notFound
        case notExecutable(path: String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                "fclones not found. Install it (e.g., `brew install fclones`) or set GARGANTUA_FCLONES_BIN."
            case .notExecutable(let path):
                "fclones at \(path) is not executable."
            }
        }
    }

    public static let envVarName = "GARGANTUA_FCLONES_BIN"

    /// Common install locations checked when the binary isn't already on the
    /// search path surfaced to a non-login shell.
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/fclones",
        "/usr/local/bin/fclones",
        "/usr/bin/fclones",
    ]

    private let environment: [String: String]
    private let bundledURL: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledURL: URL? = Bundle.main.url(forResource: "fclones", withExtension: nil)
    ) {
        self.environment = environment
        self.bundledURL = bundledURL
    }

    /// Resolve the path to fclones, or throw `.notFound`.
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

    /// Whether fclones is available without requiring the caller to catch an error.
    public func isAvailable() -> Bool {
        (try? resolve()) != nil
    }
}
