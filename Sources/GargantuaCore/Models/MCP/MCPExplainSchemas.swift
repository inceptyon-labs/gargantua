import Foundation

/// Input for `explain`: exactly one of `path` or `itemId` must be supplied.
public struct MCPExplainInput: Codable, Sendable, Equatable {
    /// Filesystem path to explain when addressing an item by path.
    public let path: String?
    /// Scan item identifier to explain when addressing a previous result.
    public let itemId: String?

    /// Creates an explain input before validation.
    public init(path: String? = nil, itemId: String? = nil) {
        self.path = path
        self.itemId = itemId
    }

    enum CodingKeys: String, CodingKey {
        case path
        case itemId = "item_id"
    }

    /// Decodes and validates that exactly one lookup key is present.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decodeIfPresent(String.self, forKey: .path)
        let itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        switch (path, itemId) {
        case (nil, nil):
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: c,
                debugDescription: "explain requires exactly one of path or item_id."
            )
        case (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: c,
                debugDescription: "explain accepts path or item_id, not both."
            )
        default:
            self.path = path
            self.itemId = itemId
        }
    }
}

/// Receipt provenance attached to an explained item.
///
/// Mirrors the relevant fields of `PackageReceipt` so an MCP client can
/// render audit-grade explanations like "we found this because
/// com.docker.docker (v4.30.0) installed it on 2025-12-04". Multiple
/// packages can claim a single path, so explain output carries an array.
public struct MCPReceiptProvenance: Codable, Sendable, Equatable {
    /// Reverse-DNS package identifier (e.g., `com.docker.docker`).
    public let pkgID: String
    /// Package version when readable from the receipt.
    public let pkgVersion: String?
    /// Install timestamp when readable from the receipt.
    public let installDate: Date?

    /// Creates a receipt provenance entry.
    public init(
        pkgID: String,
        pkgVersion: String? = nil,
        installDate: Date? = nil
    ) {
        self.pkgID = pkgID
        self.pkgVersion = pkgVersion
        self.installDate = installDate
    }

    enum CodingKeys: String, CodingKey {
        case pkgID = "pkg_id"
        case pkgVersion = "pkg_version"
        case installDate = "install_date"
    }
}

/// Explanation details returned for one scan item or path.
public struct MCPExplainOutput: Codable, Sendable, Equatable {
    /// Display name for the explained item.
    public let name: String
    /// Safety classification string for the item.
    public let safety: String
    /// Confidence score for the explanation.
    public let confidence: Int
    /// Human-readable explanation text.
    public let explanation: String
    /// Optional human-readable size string.
    public let size: String?
    /// Optional last access timestamp.
    public let lastAccessed: Date?
    /// Receipts that claim the explained path, when receipt evidence is
    /// available. Omitted (encoded as `null`) when the path is not owned
    /// by any package receipt.
    public let receipts: [MCPReceiptProvenance]?

    /// Creates an explanation output payload.
    public init(
        name: String,
        safety: String,
        confidence: Int,
        explanation: String,
        size: String? = nil,
        lastAccessed: Date? = nil,
        receipts: [MCPReceiptProvenance]? = nil
    ) {
        self.name = name
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.size = size
        self.lastAccessed = lastAccessed
        self.receipts = receipts
    }

    enum CodingKeys: String, CodingKey {
        case name, safety, confidence, explanation, size, receipts
        case lastAccessed = "last_accessed"
    }
}
