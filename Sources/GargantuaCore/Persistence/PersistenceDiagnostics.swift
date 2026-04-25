import Foundation

public enum PersistenceDiagnostics {
    public static func logFailure(_ operation: String, error: Error) {
        FileHandle.standardError.write(Data("\(operation) failed: \(error.localizedDescription)\n".utf8))
    }

    public static func logFallback(_ operation: String, fallback: String, error: Error) {
        FileHandle.standardError.write(Data("\(operation) failed; using \(fallback): \(error)\n".utf8))
    }
}
