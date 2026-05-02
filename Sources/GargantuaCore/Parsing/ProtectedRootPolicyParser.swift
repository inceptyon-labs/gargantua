import Foundation
import Yams

public enum ProtectedRootPolicyParseError: Error, LocalizedError, CustomStringConvertible {
    case invalidYAML(filePath: String, underlying: Error)
    case missingProtectedRoots(filePath: String)
    case missingField(field: String, index: Int, filePath: String)

    public var description: String {
        switch self {
        case .invalidYAML(let filePath, let underlying):
            return "\(filePath): invalid protected-root YAML — \(underlying.localizedDescription)"
        case .missingProtectedRoots(let filePath):
            return "\(filePath): missing top-level 'protected_roots' key"
        case .missingField(let field, let index, let filePath):
            return "\(filePath): protected_roots[\(index)] missing required field '\(field)'"
        }
    }

    public var errorDescription: String? { description }
}

public struct ProtectedRootPolicyParser: Sendable {
    public init() {}

    public func parse(yaml: String, filePath: String = "<string>") throws -> [ProtectedRootEntry] {
        let node: Node
        do {
            guard let parsed = try Yams.compose(yaml: yaml) else {
                throw ProtectedRootPolicyParseError.missingProtectedRoots(filePath: filePath)
            }
            node = parsed
        } catch let error as ProtectedRootPolicyParseError {
            throw error
        } catch {
            throw ProtectedRootPolicyParseError.invalidYAML(filePath: filePath, underlying: error)
        }

        guard let mapping = node.mapping,
              let rootsNode = mapping["protected_roots"],
              let roots = rootsNode.sequence else {
            throw ProtectedRootPolicyParseError.missingProtectedRoots(filePath: filePath)
        }

        return try roots.enumerated().map { index, node in
            guard let mapping = node.mapping else {
                throw ProtectedRootPolicyParseError.missingField(field: "path", index: index, filePath: filePath)
            }
            let path = try requireString("path", from: mapping, index: index, filePath: filePath)
            let reason = try requireString("reason", from: mapping, index: index, filePath: filePath)
            return ProtectedRootEntry(path: path, reason: reason, source: .bundled)
        }
    }

    private func requireString(
        _ key: String,
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> String {
        guard let value = mapping[key]?.string,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtectedRootPolicyParseError.missingField(field: key, index: index, filePath: filePath)
        }
        return value
    }
}

public struct ProtectedRootPolicyLoader: Sendable {
    private let parser = ProtectedRootPolicyParser()

    public init() {}

    public func loadBundled() throws -> ProtectedRootPolicy {
        guard let url = ProtectedRootPolicyResolver.bundledPolicyURL() else {
            throw ProtectedRootPolicyLoadError.bundledPolicyNotFound
        }
        return try load(from: url)
    }

    public func load(from url: URL) throws -> ProtectedRootPolicy {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let entries = try parser.parse(yaml: yaml, filePath: url.path)
        return ProtectedRootPolicy(entries: entries)
    }
}

public enum ProtectedRootPolicyLoadError: Error, LocalizedError {
    case bundledPolicyNotFound

    public var errorDescription: String? {
        switch self {
        case .bundledPolicyNotFound:
            return "Bundled protected-root policy was not found."
        }
    }
}

public enum ProtectedRootPolicyResolver {
    public static func bundledPolicyURL() -> URL? {
        Bundle.module.url(forResource: "safety_policy", withExtension: nil)?
            .appendingPathComponent("protected_roots.yaml")
    }
}
