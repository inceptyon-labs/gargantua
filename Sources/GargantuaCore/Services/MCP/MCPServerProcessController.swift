import Foundation

private struct MCPServerLaunchDescriptor: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?
}

public enum MCPServerProcessController {
    private static let readinessTimeout: TimeInterval = 20
    private static let readinessPollInterval: TimeInterval = 0.1

    public static func startSSEServer() throws -> MCPServerStatusSnapshot {
        try startSSEServerWithDependencies(
            persistence: MCPServerStatusPersistence(),
            configurationStore: MCPSSEConfigurationStore(),
            tokenManager: MCPBearerTokenManager(),
            fileManager: .default,
            now: { Date() },
            launcher: { try launchProcess($0) }
        )
    }

    fileprivate static func startSSEServerWithDependencies(
        persistence: MCPServerStatusPersistence = MCPServerStatusPersistence(),
        configurationStore: MCPSSEConfigurationStore = MCPSSEConfigurationStore(),
        tokenManager: MCPBearerTokenManager = MCPBearerTokenManager(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        launcher: @escaping @Sendable (MCPServerLaunchDescriptor) throws -> Void
    ) throws -> MCPServerStatusSnapshot {
        let existing = try persistence.readSnapshot(now: now())
        if existing.state == .running {
            return existing
        }

        var configuration = configurationStore.load()
        configuration.isEnabled = true
        try configuration.validate(hasBearerToken: tokenManager.hasToken())
        configurationStore.save(configuration)

        let launch = try defaultSSELaunch(fileManager: fileManager)
        let launchedAt = now()
        try launcher(launch)
        return try waitForReadySnapshot(
            persistence: persistence,
            launchedAt: launchedAt,
            now: now
        )
    }

    private static func defaultSSELaunch(fileManager: FileManager) throws -> MCPServerLaunchDescriptor {
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundledMCP = executableDirectory.appendingPathComponent("GargantuaMCP")
            if fileManager.isExecutableFile(atPath: bundledMCP.path) {
                return MCPServerLaunchDescriptor(
                    executableURL: bundledMCP,
                    arguments: ["--sse"],
                    workingDirectory: nil
                )
            }
        }

        guard let packageRoot = packageRootURL(fileManager: fileManager) else {
            throw MCPServerControlError.unsupported("GargantuaMCP executable was not found.")
        }

        return MCPServerLaunchDescriptor(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "run", "GargantuaMCP", "--", "--sse"],
            workingDirectory: packageRoot
        )
    }

    private static func packageRootURL(fileManager: FileManager) -> URL? {
        let candidates = [
            Bundle.main.executableURL,
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
        ].compactMap { $0 }

        for candidate in candidates {
            if let root = firstAncestorContainingPackageManifest(
                from: candidate,
                fileManager: fileManager
            ) {
                return root
            }
        }
        return nil
    }

    private static func firstAncestorContainingPackageManifest(
        from url: URL,
        fileManager: FileManager
    ) -> URL? {
        var current = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let manifest = current.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: manifest.path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func launchProcess(_ launch: MCPServerLaunchDescriptor) throws {
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        process.environment = ProcessInfo.processInfo.environment

        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        MCPServerChildProcessRegistry.shared.retain(process)
        do {
            try process.run()
        } catch {
            MCPServerChildProcessRegistry.shared.release(process)
            throw MCPServerControlError.unsupported("MCP server could not be launched: \(error.localizedDescription)")
        }
    }

    private static func waitForReadySnapshot(
        persistence: MCPServerStatusPersistence,
        launchedAt: Date,
        now: @escaping @Sendable () -> Date
    ) throws -> MCPServerStatusSnapshot {
        let staleCutoff = launchedAt.addingTimeInterval(-1)
        let deadline = launchedAt.addingTimeInterval(readinessTimeout)

        while now() < deadline {
            let snapshot = try persistence.readSnapshot(now: now())
            if snapshot.updatedAt >= staleCutoff {
                switch snapshot.state {
                case .running, .error:
                    return snapshot
                case .starting, .stopped:
                    break
                }
            }
            Thread.sleep(forTimeInterval: readinessPollInterval)
        }

        throw MCPServerControlError.unsupported("MCP server launched but did not report ready.")
    }
}

private final class MCPServerChildProcessRegistry: @unchecked Sendable {
    static let shared = MCPServerChildProcessRegistry()

    private let lock = NSLock()
    private var processes: [Process] = []

    private init() {}

    func retain(_ process: Process) {
        lock.lock()
        processes.append(process)
        lock.unlock()

        process.terminationHandler = { [weak self] terminated in
            self?.release(terminated)
        }
    }

    func release(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }
}
