import Foundation
import Testing
@testable import GargantuaCore

@Suite("CloudAIKeychain")
struct CloudAIKeychainTests {

    // MARK: - CloudAPIKeyValidator

    @Suite("CloudAPIKeyValidator")
    struct ValidatorTests {
        @Test("normalized strips leading and trailing whitespace")
        func normalizedStripsWhitespace() {
            #expect(CloudAPIKeyValidator.normalized("  hello  ") == "hello")
            #expect(CloudAPIKeyValidator.normalized("\nsk-ant-test\t") == "sk-ant-test")
        }

        @Test("normalized returns empty string unchanged")
        func normalizedEmpty() {
            #expect(CloudAPIKeyValidator.normalized("") == "")
        }

        @Test("isPlausibleAnthropicKey accepts sk-ant- prefix with sufficient length")
        func acceptsValidKey() {
            let key = "sk-ant-api03-" + String(repeating: "x", count: 20)
            #expect(CloudAPIKeyValidator.isPlausibleAnthropicKey(key))
        }

        @Test("isPlausibleAnthropicKey rejects key shorter than 24 characters")
        func rejectsTooShort() {
            #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey("sk-ant-short"))
        }

        @Test("isPlausibleAnthropicKey rejects key with embedded whitespace")
        func rejectsEmbeddedWhitespace() {
            let key = "sk-ant-api03-" + "a bc" + String(repeating: "x", count: 20)
            #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey(key))
        }

        @Test("isPlausibleAnthropicKey rejects non-Anthropic prefix")
        func rejectsWrongPrefix() {
            let key = "sk-openai-" + String(repeating: "x", count: 30)
            #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey(key))
        }

        @Test("isPlausibleAnthropicKey trims before checking")
        func trimsBeforeCheck() {
            let key = "  sk-ant-api03-" + String(repeating: "z", count: 20) + "  "
            #expect(CloudAPIKeyValidator.isPlausibleAnthropicKey(key))
        }

        @Test("isPlausibleAnthropicKey rejects empty string")
        func rejectsEmpty() {
            #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey(""))
        }

        @Test("isPlausibleAnthropicKey rejects key that is only prefix")
        func rejectsOnlyPrefix() {
            #expect(!CloudAPIKeyValidator.isPlausibleAnthropicKey("sk-ant-"))
        }
    }

    // MARK: - KeychainCloudAPIKeyStoreError

    @Suite("KeychainCloudAPIKeyStoreError")
    struct StoreErrorTests {
        @Test("errorDescription is non-nil for a known OS status")
        func errorDescriptionNonNil() {
            let err = KeychainCloudAPIKeyStoreError(status: errSecParam)
            #expect(err.errorDescription != nil)
        }

        @Test("errorDescription falls back for unknown status")
        func errorDescriptionFallback() {
            // An OSStatus of 42 is not a real Keychain code; the fallback
            // branch must still produce a non-empty string.
            let err = KeychainCloudAPIKeyStoreError(status: 42)
            let desc = err.errorDescription ?? ""
            #expect(!desc.isEmpty)
        }

        @Test("two errors with the same status are equal")
        func equalityBySameStatus() {
            let a = KeychainCloudAPIKeyStoreError(status: errSecItemNotFound)
            let b = KeychainCloudAPIKeyStoreError(status: errSecItemNotFound)
            #expect(a == b)
        }

        @Test("two errors with different statuses are not equal")
        func inequalityByDifferentStatus() {
            let a = KeychainCloudAPIKeyStoreError(status: errSecItemNotFound)
            let b = KeychainCloudAPIKeyStoreError(status: errSecDuplicateItem)
            #expect(a != b)
        }
    }

    // MARK: - KeychainCloudAPIKeyStore

    @Suite("KeychainCloudAPIKeyStore")
    struct StoreTests {
        private func uniqueStore() -> KeychainCloudAPIKeyStore {
            KeychainCloudAPIKeyStore(
                service: "com.gargantua.tests.\(UUID().uuidString)",
                account: "test-key"
            )
        }

        @Test("save rejects invalid API key before touching Keychain")
        func saveRejectsInvalidKey() {
            let store = uniqueStore()
            #expect(throws: CloudAIError.invalidAPIKey) {
                try store.save("not-a-real-key")
            }
        }

        @Test("save rejects empty key")
        func saveRejectsEmptyKey() {
            let store = uniqueStore()
            #expect(throws: CloudAIError.invalidAPIKey) {
                try store.save("")
            }
        }

        @Test("hasKey returns false on a fresh store")
        func hasKeyFalseWhenEmpty() throws {
            let store = uniqueStore()
            #expect(try store.hasKey() == false)
        }

        @Test("read returns nil on a fresh store")
        func readNilWhenEmpty() throws {
            let store = uniqueStore()
            #expect(try store.read() == nil)
        }

        @Test("save, read, and delete round-trip")
        func saveReadDeleteRoundTrip() throws {
            let store = uniqueStore()
            let key = "sk-ant-api03-" + String(repeating: "t", count: 30)
            try store.save(key)

            #expect(try store.read() == key)
            #expect(try store.hasKey() == true)

            try store.delete()
            #expect(try store.read() == nil)
            #expect(try store.hasKey() == false)
        }

        @Test("save overwrites existing key")
        func saveOverwritesExistingKey() throws {
            let store = uniqueStore()
            let first = "sk-ant-api03-" + String(repeating: "a", count: 30)
            let second = "sk-ant-api03-" + String(repeating: "b", count: 30)
            try store.save(first)
            try store.save(second)
            #expect(try store.read() == second)
            try store.delete()
        }

        @Test("save trims whitespace from key before storing")
        func saveTrimmedKey() throws {
            let store = uniqueStore()
            let raw = "  sk-ant-api03-" + String(repeating: "c", count: 30) + "\n"
            let expected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.save(raw)
            #expect(try store.read() == expected)
            try store.delete()
        }

        @Test("delete is idempotent — no error when key is absent")
        func deleteIdempotent() throws {
            let store = uniqueStore()
            #expect(throws: Never.self) {
                try store.delete()
                try store.delete()
            }
        }
    }
}
