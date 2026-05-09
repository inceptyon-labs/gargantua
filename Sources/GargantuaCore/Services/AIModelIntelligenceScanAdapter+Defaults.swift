import Foundation

extension AIModelIntelligenceScanAdapter {
    public static func defaultKnownStores(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [AIModelStoreDefinition] {
        func home(_ path: String) -> URL {
            homeDirectory.appendingPathComponent(path, isDirectory: true)
        }

        return [
            AIModelStoreDefinition(
                id: "ollama",
                displayName: "Ollama",
                roots: [home(".ollama/models")],
                includeExtensionlessLargeFiles: true
            ),
            AIModelStoreDefinition(
                id: "lm-studio",
                displayName: "LM Studio",
                roots: [
                    home(".cache/lm-studio/models"),
                    home(".lmstudio/models"),
                    home("Library/Application Support/LM Studio/models"),
                    home("Library/Application Support/lmstudio/models"),
                ]
            ),
            AIModelStoreDefinition(
                id: "hugging-face",
                displayName: "Hugging Face",
                roots: [
                    home(".cache/huggingface"),
                    home("Library/Caches/huggingface"),
                ]
            ),
            AIModelStoreDefinition(
                id: "comfyui",
                displayName: "ComfyUI",
                roots: [
                    home("ComfyUI/models"),
                    home("Documents/ComfyUI/models"),
                ]
            ),
            AIModelStoreDefinition(
                id: "stable-diffusion-webui",
                displayName: "Stable Diffusion WebUI",
                roots: [
                    home("stable-diffusion-webui/models"),
                    home("Documents/stable-diffusion-webui/models"),
                ]
            ),
            AIModelStoreDefinition(
                id: "pinokio",
                displayName: "Pinokio",
                roots: [home("pinokio")],
            ),
        ]
    }

    public static func defaultOrphanRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        scanRoots: [URL]? = nil
    ) -> [URL] {
        var seen = Set<String>()
        let defaultRoots = ["Downloads", "Documents", "Desktop"].map {
            homeDirectory.appendingPathComponent($0, isDirectory: true)
        }
        return ((scanRoots ?? []) + defaultRoots).filter {
            seen.insert(AIModelScanPolicy.normalizedPath($0.path)).inserted
        }
    }
}
