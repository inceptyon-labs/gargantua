import Foundation

/// Evaluates condition expressions from safety overrides and match filters
/// against file metadata.
///
/// Supported expressions:
/// - `age > Nd` — file older than N days (last access, falling back to mtime)
/// - `atime > Nh` — file older than N hours by last-access time
/// - `mtime > Nm` — file older than N minutes by modification time
public struct ConditionEvaluator: Sendable {

    public init() {}

    /// Evaluate a condition string against file metadata.
    ///
    /// - Parameters:
    ///   - condition: The condition expression (e.g., "age > 30d").
    ///   - lastAccessed: The file's last accessed date. Returns `false` if nil.
    ///   - now: Reference date for age calculation (defaults to current date).
    /// - Returns: Whether the condition is satisfied.
    public func evaluate(condition: String, lastAccessed: Date?, now: Date = Date()) -> Bool {
        evaluate(condition: condition, lastAccessed: lastAccessed, modifiedAt: nil, now: now)
    }

    /// Evaluate a condition string against access and modification metadata.
    public func evaluate(
        condition: String,
        lastAccessed: Date?,
        modifiedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        let trimmed = condition.trimmingCharacters(in: .whitespaces)

        if let parsed = parseAgeCondition(trimmed) {
            let reference: Date?
            switch parsed.field {
            case .age:
                reference = lastAccessed ?? modifiedAt
            case .atime:
                reference = lastAccessed
            case .mtime:
                reference = modifiedAt
            }

            guard let reference else { return false }
            let fileAge = now.timeIntervalSince(reference)
            switch parsed.op {
            case .greaterThan: return fileAge > parsed.threshold
            case .greaterThanOrEqual: return fileAge >= parsed.threshold
            case .lessThan: return fileAge < parsed.threshold
            case .lessThanOrEqual: return fileAge <= parsed.threshold
            }
        }

        return false
    }
}

// MARK: - Parsing

private extension ConditionEvaluator {

    enum ComparisonOp {
        case greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    }

    enum DateField {
        case age, atime, mtime
    }

    struct AgeCondition {
        let field: DateField
        let op: ComparisonOp
        let threshold: TimeInterval
    }

    static let dateFields: [String: DateField] = [
        "age": .age,
        "atime": .atime,
        "mtime": .mtime,
    ]

    static let comparisonOps: [String: ComparisonOp] = [
        ">": .greaterThan,
        ">=": .greaterThanOrEqual,
        "<": .lessThan,
        "<=": .lessThanOrEqual,
    ]

    static let unitMultipliers: [String: TimeInterval] = [
        "d": 86400,
        "h": 3600,
        "m": 60,
    ]

    /// Parse "age > 30d", "age >= 7d", "age < 1h", etc.
    func parseAgeCondition(_ condition: String) -> AgeCondition? {
        let pattern = #/^(age|atime|mtime)\s*(>=|<=|>|<)\s*(\d+)([dhm])$/#
        guard let match = try? pattern.firstMatch(in: condition),
              let field = Self.dateFields[String(match.output.1)],
              let op = Self.comparisonOps[String(match.output.2)],
              let multiplier = Self.unitMultipliers[String(match.output.4)]
        else { return nil }

        let value = Double(String(match.output.3)) ?? 0
        return AgeCondition(field: field, op: op, threshold: value * multiplier)
    }
}
