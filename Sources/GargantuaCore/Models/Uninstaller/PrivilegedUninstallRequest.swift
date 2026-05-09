import Foundation

/// Structured command passed across the privileged uninstall boundary.
///
/// The helper side should treat this as a bounded plan, not as permission to
/// operate on arbitrary root-owned paths.
public struct PrivilegedUninstallRequest: Codable, Sendable, Equatable {
    public let planID: UUID
    public let items: [PrivilegedUninstallItem]
    public let createdAt: Date

    public init(
        planID: UUID,
        items: [PrivilegedUninstallItem],
        createdAt: Date = Date()
    ) {
        self.planID = planID
        self.items = items
        self.createdAt = createdAt
    }
}

/// Helper-side result payload returned over the privileged XPC boundary.
public struct PrivilegedUninstallResponse: Codable, Sendable, Equatable {
    public let items: [PrivilegedUninstallItemResult]

    public init(items: [PrivilegedUninstallItemResult]) {
        self.items = items
    }
}

/// Single removable item in a privileged uninstall request.
public struct PrivilegedUninstallItem: Codable, Sendable, Equatable, Identifiable {
    public enum Operation: String, Codable, Sendable {
        case moveToTrash = "move_to_trash"
    }

    public let id: String
    public let path: String
    public let category: String
    public let size: Int64
    public let operation: Operation

    public init(
        id: String,
        path: String,
        category: String,
        size: Int64,
        operation: Operation = .moveToTrash
    ) {
        self.id = id
        self.path = path
        self.category = category
        self.size = size
        self.operation = operation
    }
}

/// Result for one item in a privileged uninstall request.
public struct PrivilegedUninstallItemResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let succeeded: Bool
    public let trashPath: String?
    public let error: String?

    public init(
        id: String,
        path: String,
        succeeded: Bool,
        trashPath: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.path = path
        self.succeeded = succeeded
        self.trashPath = trashPath
        self.error = error
    }
}

/// Error payload used when the helper cannot decode or execute a request.
public struct PrivilegedUninstallErrorResponse: Codable, Sendable, Equatable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}

@objc public protocol PrivilegedUninstallXPCProtocol {
    func moveItemsToTrash(
        requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )

    /// Perform a single Background Items operation (disable / enable /
    /// bootout / bootstrap / trash plist). The helper validates `requestData`
    /// against `PrivilegedBackgroundItemRequest` and runs the matching
    /// subprocess or trash op. Reply is `PrivilegedBackgroundItemResponse`,
    /// JSON-encoded; on a decode failure the helper returns
    /// `PrivilegedUninstallErrorResponse` so the existing error path is reusable.
    func performBackgroundItemAction(
        requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )
}

public enum PrivilegedUninstallXPCCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension PrivilegedUninstallRequest {
    public init(planID: UUID, scanResults: [ScanResult], createdAt: Date = Date()) {
        self.init(
            planID: planID,
            items: scanResults.map(PrivilegedUninstallItem.init(scanResult:)),
            createdAt: createdAt
        )
    }
}

extension PrivilegedUninstallItem {
    public init(scanResult: ScanResult) {
        self.init(
            id: scanResult.id,
            path: scanResult.path,
            category: scanResult.category,
            size: scanResult.size
        )
    }
}
