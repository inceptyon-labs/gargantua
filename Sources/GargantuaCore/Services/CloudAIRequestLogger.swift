import Foundation

public struct CloudAIRequestLogEntry: Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let feature: CloudAIFeature
    public let model: String
    public let estimatedCostCents: Int
    public let actualCostCents: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let status: String
    public let metadata: [String: String]
    public let requestID: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        feature: CloudAIFeature,
        model: String,
        estimatedCostCents: Int,
        actualCostCents: Int,
        inputTokens: Int,
        outputTokens: Int,
        status: String,
        metadata: [String: String],
        requestID: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.feature = feature
        self.model = model
        self.estimatedCostCents = estimatedCostCents
        self.actualCostCents = actualCostCents
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.status = status
        self.metadata = metadata
        self.requestID = requestID
    }
}

public actor CloudAIRequestLogger {
    private let logURL: URL
    private let encoder: JSONEncoder
    private let fileManager: FileManager

    public init(logURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.logURL = logURL ?? Self.defaultLogURL(fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func append(_ entry: CloudAIRequestLogEntry) throws {
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A)

        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: logURL, options: .atomic)
        }
    }

    public func entries() throws -> [CloudAIRequestLogEntry] {
        guard fileManager.fileExists(atPath: logURL.path) else { return [] }
        let data = try Data(contentsOf: logURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(CloudAIRequestLogEntry.self, from: Data(line.utf8))
            }
    }

    private static func defaultLogURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Gargantua", isDirectory: true)
            .appendingPathComponent("cloud-ai-requests.jsonl")
    }
}
