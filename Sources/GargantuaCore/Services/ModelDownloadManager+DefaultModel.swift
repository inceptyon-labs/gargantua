import Foundation

extension ModelDownloadManager {
    /// `mlx-community/Llama-3.2-1B-Instruct-4bit` — per PRD §6.2 and the xuz6
    /// design doc. File SHAs are pinned from the HF LFS pointers (safetensors +
    /// tokenizer.json) and direct content hashes (small JSON files); regenerate
    /// via `Scripts/pin-model.sh` if the upstream repo is ever bumped.
    public nonisolated static let defaultModel = ModelInfo(
        id: "Llama-3.2-1B-Instruct-4bit",
        name: "Llama 3.2 1B Instruct (4-bit MLX)",
        files: [
            ModelFile(
                name: "config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/config.json")!,
                sha256: "73bfb89e5a43c76ada2d7a9609862139578a71cfbb43e30bf5d4571026dd3741",
                size: 1_121
            ),
            ModelFile(
                name: "tokenizer_config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/tokenizer_config.json")!,
                sha256: "022d5ae3df4737998ab97d8f31ac2bcb4c06dd8ebe5a8aba2b4aceef1e5ea7d3",
                size: 54_558
            ),
            ModelFile(
                name: "special_tokens_map.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/special_tokens_map.json")!,
                sha256: "6f38c73729248f6c127296386e3cdde96e254636cc58b4169d3fd32328d9a8ec",
                size: 296
            ),
            ModelFile(
                name: "tokenizer.json",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/tokenizer.json")!,
                sha256: "6b9e4e7fb171f92fd137b777cc2714bf87d11576700a1dcd7a399e7bbe39537b",
                size: 17_209_920
            ),
            ModelFile(
                name: "model.safetensors",
                url: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main/model.safetensors")!,
                sha256: "35e396644bca888eec399f9c0f843ec7fa78b8f8c5e06841661be62b4edf96dd",
                size: 695_283_921
            ),
        ]
    )
}
