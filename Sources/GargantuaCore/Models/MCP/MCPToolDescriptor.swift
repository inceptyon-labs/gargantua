import Foundation

/// Stable identifier for every MCP tool exposed by the server across phases.
///
/// Phase 2 exposes read-only tools plus a dry-run `scan`. Phase 3 adds the
/// destructive `clean` tool, registered through `MCPPhase3Tools` and never
/// mixed into `MCPPhase2Tools.all` — Phase 2 server entry points must stay
/// free of destructive capabilities.
public enum MCPToolName: String, Codable, Sendable, CaseIterable {
    case scan
    case analyze
    case explain
    case listProfiles = "list_profiles"
    case status
    case clean
}

/// A self-describing MCP tool definition: name, human description, and a
/// JSON Schema payload ready for the `tools/list` response.
///
/// The schema is stored as structured `MCPJSONSchema` values so it can be
/// encoded directly into JSON without string interpolation, and inspected by
/// tests to verify invariants (e.g. `scan.dry_run` is a constant `true`).
public struct MCPToolDescriptor: Codable, Sendable {
    public let name: MCPToolName
    public let description: String
    public let inputSchema: MCPJSONSchema

    public init(name: MCPToolName, description: String, inputSchema: MCPJSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Minimal JSON Schema subset used for MCP tool input descriptors.
///
/// Only the constructs used by the Phase 2 tools are modeled; extending
/// to a fuller JSON Schema is left for follow-up work if richer validation
/// is needed server-side.
public struct MCPJSONSchema: Codable, Sendable, Equatable {
    public enum SchemaType: String, Codable, Sendable {
        case object
        case array
        case string
        case integer
        case number
        case boolean
    }

    public let type: SchemaType
    public let description: String?

    /// For `object` types: property schemas keyed by property name.
    public let properties: [String: MCPJSONSchema]?

    /// For `object` types: required property names (in a stable order).
    public let required: [String]?

    /// For `string` types with a fixed set of values.
    public let enumValues: [String]?

    /// For `boolean`/`string` types pinned to a constant.
    ///
    /// Encoded as JSON Schema `const`. Used for `scan.dry_run = true`.
    public let const: MCPJSONValue?

    /// For `array` types: item schema.
    public let items: Box<MCPJSONSchema>?

    /// For schemas that must satisfy exactly one of several sub-schemas.
    ///
    /// Used on `explain` to advertise that exactly one of `path` or
    /// `item_id` must be provided — a constraint that plain optional
    /// properties cannot express to schema-driven MCP clients.
    public let oneOf: [MCPJSONSchema]?

    public init(
        type: SchemaType,
        description: String? = nil,
        properties: [String: MCPJSONSchema]? = nil,
        required: [String]? = nil,
        enumValues: [String]? = nil,
        const: MCPJSONValue? = nil,
        items: MCPJSONSchema? = nil,
        oneOf: [MCPJSONSchema]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.enumValues = enumValues
        self.const = const
        self.items = items.map(Box.init)
        self.oneOf = oneOf
    }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items, const, oneOf
        case enumValues = "enum"
    }
}

/// Boxed reference so `MCPJSONSchema` can recursively describe array items.
public final class Box<Wrapped: Codable & Sendable & Equatable>: Codable, @unchecked Sendable, Equatable {
    public let value: Wrapped
    public init(_ value: Wrapped) { self.value = value }

    public init(from decoder: Decoder) throws {
        self.value = try Wrapped(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
    public static func == (lhs: Box<Wrapped>, rhs: Box<Wrapped>) -> Bool {
        lhs.value == rhs.value
    }
}

/// Minimal typed JSON value, used for schema `const` and `default` payloads.
public enum MCPJSONValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case integer(Int)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported MCPJSONValue"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b):    try c.encode(b)
        case .string(let s):  try c.encode(s)
        case .integer(let i): try c.encode(i)
        case .number(let d):  try c.encode(d)
        }
    }
}

// MARK: - Phase 2 Tool Registry

/// The canonical Phase 2 tool registry.
///
/// Exactly five tools are defined (PRD §7.3). The destructive `clean` tool
/// lives in `MCPPhase3Tools` so Phase 2 code paths cannot accidentally
/// advertise destructive capabilities.
public enum MCPPhase2Tools {
    public static let all: [MCPToolDescriptor] = [
        scan,
        analyze,
        explain,
        listProfiles,
        status,
    ]

    // MARK: scan

    /// `scan` is **always dry-run** over MCP. The schema pins `dry_run` to
    /// the constant `true` so no client can toggle it off.
    public static let scan = MCPToolDescriptor(
        name: .scan,
        description: "Scan the Mac for reclaimable space. Returns categorized results with safety levels. Always dry-run; cannot delete.",
        inputSchema: MCPJSONSchema(
            type: .object,
            description: "Inputs for the scan tool. dry_run is constant true and cannot be overridden.",
            properties: [
                "profile": MCPJSONSchema(
                    type: .string,
                    description: "Cleanup profile identifier from list_profiles. Defaults to the active profile."
                ),
                "categories": MCPJSONSchema(
                    type: .array,
                    description: "Categories to scan; overrides the profile's category list when present.",
                    items: MCPJSONSchema(type: .string)
                ),
                "dry_run": MCPJSONSchema(
                    type: .boolean,
                    description: "Always true when called via MCP.",
                    const: .bool(true)
                ),
            ],
            required: ["dry_run"]
        )
    )

    // MARK: analyze

    public static let analyze = MCPToolDescriptor(
        name: .analyze,
        description: "Get system health score, disk usage breakdown, and recommendations.",
        inputSchema: MCPJSONSchema(
            type: .object,
            description: "No inputs.",
            properties: [:],
            required: []
        )
    )

    // MARK: explain

    public static let explain = MCPToolDescriptor(
        name: .explain,
        description: "Explain what a file or directory is, its safety level, and whether it can be cleaned.",
        inputSchema: MCPJSONSchema(
            type: .object,
            description: "Provide either a filesystem path or an item id from a prior scan.",
            properties: [
                "path": MCPJSONSchema(
                    type: .string,
                    description: "Absolute filesystem path to explain. Mutually exclusive with item_id."
                ),
                "item_id": MCPJSONSchema(
                    type: .string,
                    description: "Item id from a prior scan result. Mutually exclusive with path."
                ),
            ],
            required: [],
            oneOf: [
                MCPJSONSchema(type: .object, required: ["path"]),
                MCPJSONSchema(type: .object, required: ["item_id"]),
            ]
        )
    )

    // MARK: list_profiles

    public static let listProfiles = MCPToolDescriptor(
        name: .listProfiles,
        description: "List available cleanup profiles and their categories.",
        inputSchema: MCPJSONSchema(
            type: .object,
            description: "No inputs.",
            properties: [:],
            required: []
        )
    )

    // MARK: status

    public static let status = MCPToolDescriptor(
        name: .status,
        description: "Get real-time system health metrics (CPU, memory, disk, thermal).",
        inputSchema: MCPJSONSchema(
            type: .object,
            description: "No inputs.",
            properties: [:],
            required: []
        )
    )
}
