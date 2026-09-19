import Foundation

extension AISessionScanAdapter {
    /// The session stores Gargantua knows how to read a project path out of,
    /// filtered to the ones present on this machine.
    public static func defaultStores(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [AISessionStore] {
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        // The VS Code family all inherit the same `User/workspaceStorage` layout,
        // which is where their AI assistants (Copilot Chat, Cursor, Cascade) park
        // per-workspace state alongside the editor's own.
        let workspaceStorageTools = ["Code": "VS Code", "Cursor": "Cursor", "Windsurf": "Windsurf", "VSCodium": "VSCodium"]

        var stores = [
            AISessionStore(
                toolName: "Claude Code",
                kind: .claudeCodeProject,
                url: homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
            ),
        ]
        stores += workspaceStorageTools
            .sorted { $0.key < $1.key }
            .map { directoryName, toolName in
                AISessionStore(
                    toolName: toolName,
                    kind: .editorWorkspaceStorage,
                    url: applicationSupport
                        .appendingPathComponent(directoryName, isDirectory: true)
                        .appendingPathComponent("User/workspaceStorage", isDirectory: true)
                )
            }

        // The scratchpad root is per-uid: /private/tmp/claude-<uid>. Only this
        // user's is ever scanned.
        stores.append(AISessionStore(
            toolName: "Claude Code",
            kind: .agentScratchpad,
            url: URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
        ))

        return stores.filter { store in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: store.url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func loadDefaults(
        categories: Set<String>? = nil,
        excludedPaths: Set<String> = [],
        protectedRoots: ProtectedRootPolicy = .loadDefault()
    ) -> AISessionScanAdapter {
        AISessionScanAdapter(
            policy: AISessionScanPolicy(
                stores: defaultStores(),
                excludedPaths: excludedPaths,
                protectedRoots: protectedRoots
            ),
            categories: categories
        )
    }
}
