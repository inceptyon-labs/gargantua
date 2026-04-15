import Foundation

/// Evaluates condition expressions from safety overrides against file metadata.
///
/// Supported expressions:
/// - `age > Nd` — file older than N days (based on last accessed date)
/// - `age > Nh` — file older than N hours
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
        guard let lastAccessed else { return false }

        let trimmed = condition.trimmingCharacters(in: .whitespaces)

        if let parsed = parseAgeCondition(trimmed) {
            let fileAge = now.timeIntervalSince(lastAccessed)
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

    struct AgeCondition {
        let op: ComparisonOp
        let threshold: TimeInterval
    }

    /// Parse "age > 30d", "age >= 7d", "age < 1h", etc.
    func parseAgeCondition(_ condition: String) -> AgeCondition? {
        let pattern = #/^age\s*(>=|<=|>|<)\s*(\d+)([dhm])$/#
        guard let match = try? pattern.firstMatch(in: condition) else { return nil }

        let opStr = String(match.output.1)
        let value = Double(String(match.output.2)) ?? 0
        let unit = String(match.output.3)

        let op: ComparisonOp
        switch opStr {
        case ">": op = .greaterThan
        case ">=": op = .greaterThanOrEqual
        case "<": op = .lessThan
        case "<=": op = .lessThanOrEqual
        default: return nil
        }

        let multiplier: TimeInterval
        switch unit {
        case "d": multiplier = 86400       // seconds per day
        case "h": multiplier = 3600        // seconds per hour
        case "m": multiplier = 60          // seconds per minute
        default: return nil
        }

        return AgeCondition(op: op, threshold: value * multiplier)
    }
}
