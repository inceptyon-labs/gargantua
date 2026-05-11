import Foundation

extension DeveloperToolPreviewAdapter {
    func cargoPreview(executable: URL) -> DeveloperToolPreview {
        let arguments = Self.previewArguments(for: .cargo)
        let commandPreview = [executable.path] + arguments
        let items = Self.cargoCachePreviewItems(cargoHome: cargoHome, commandPreview: commandPreview)
        return DeveloperToolPreview(
            tool: .cargo,
            commandPreview: commandPreview,
            items: items,
            rawOutput: cargoHome.path
        )
    }

    static func defaultCargoHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["CARGO_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return homeDirectory.appendingPathComponent(".cargo", isDirectory: true)
    }

    static func cargoCachePreviewItems(
        cargoHome: URL,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        let registrySrc = cargoHome
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("src", isDirectory: true)
        let gitCheckouts = cargoHome
            .appendingPathComponent("git", isDirectory: true)
            .appendingPathComponent("checkouts", isDirectory: true)

        return [
            cargoCachePreviewItem(
                id: "cargo-registry-src",
                title: "Cargo extracted registry sources",
                url: registrySrc,
                commandPreview: commandPreview
            ),
            cargoCachePreviewItem(
                id: "cargo-git-checkouts",
                title: "Cargo git dependency checkouts",
                url: gitCheckouts,
                commandPreview: commandPreview
            ),
        ].compactMap(\.self)
    }

    private static func cargoCachePreviewItem(
        id: String,
        title: String,
        url: URL,
        commandPreview: [String]
    ) -> DeveloperToolPreviewItem? {
        guard directoryExists(at: url) else { return nil }
        return DeveloperToolPreviewItem(
            id: id,
            tool: .cargo,
            title: title,
            detail: url.path,
            reclaimableBytes: directorySize(at: url),
            commandPreview: commandPreview
        )
    }
}
