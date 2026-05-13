import Testing
import Foundation
@testable import GargantuaCore

private func makeHandler(
    scanner: @escaping MCPScanToolHandler.Scanner,
    resolver: @escaping MCPScanToolHandler.ProfileResolver = { _ in .light }
) -> MCPScanToolHandler {
    MCPScanToolHandler(scanner: scanner, profileResolver: resolver)
}

private func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
    MCPToolArguments(dict)
}

private let minimalArguments = MCPToolArguments(["dry_run": .bool(true)])

@Suite("MCP scan tool handler profile resolution and categories override")
struct MCPScanToolHandlerProfileTests {

    // MARK: - Profile resolution

    @Test("resolver is called with nil when profile omitted")
    func resolverReceivesNilForOmittedProfile() throws {
        let received = CapturedProfileRequest()
        let subject = makeHandler(
            scanner: { _ in [] },
            resolver: { requested in
                received.value = .some(requested)
                return .light
            }
        )
        _ = try subject.handle(minimalArguments)
        #expect(received.value == .some(nil))
    }

    @Test("resolver is called with the decoded profile name")
    func resolverReceivesProfileName() throws {
        let received = CapturedProfileRequest()
        let subject = makeHandler(
            scanner: { _ in [] },
            resolver: { requested in
                received.value = .some(requested)
                return .developer
            }
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "profile": .string("developer"),
        ]))
        #expect(received.value == .some("developer"))
    }

    @Test("resolver rejection surfaces as invalidParams")
    func resolverRejection() throws {
        let subject = makeHandler(
            scanner: { _ in [] },
            resolver: { _ in throw MCPToolError.invalidParams("Unknown profile: bogus") }
        )
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(true),
                "profile": .string("bogus"),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "Unknown profile: bogus")
        }
    }

    // MARK: - Categories override

    @Test("categories override replaces profile categories in the effective profile")
    func categoriesOverrideApplied() throws {
        let receivedCategories = CapturedCategories()
        let resolver: MCPScanToolHandler.ProfileResolver = { _ in .developer }
        let subject = makeHandler(
            scanner: { profile in
                receivedCategories.value = profile.categories
                return []
            },
            resolver: resolver
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "categories": .array([.string("browser_cache"), .string("trash")]),
        ]))
        #expect(receivedCategories.value == ["browser_cache", "trash"])
    }

    @Test("categories override preserves other profile fields (id, overrides)")
    func categoriesOverridePreservesOtherFields() throws {
        let receivedProfile = CapturedProfile()
        let subject = makeHandler(
            scanner: { profile in
                receivedProfile.value = profile
                return []
            },
            resolver: { _ in .developer }
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "categories": .array([.string("browser_cache")]),
        ]))
        let profile = try #require(receivedProfile.value)
        #expect(profile.id == CleanupProfile.developer.id)
        #expect(profile.name == CleanupProfile.developer.name)
        #expect(profile.safetyOverrides.count == CleanupProfile.developer.safetyOverrides.count)
    }

    @Test("omitted categories leaves profile categories intact")
    func omittedCategoriesLeavesProfileIntact() throws {
        let receivedCategories = CapturedCategories()
        let subject = makeHandler(
            scanner: { profile in
                receivedCategories.value = profile.categories
                return []
            },
            resolver: { _ in .developer }
        )
        _ = try subject.handle(minimalArguments)
        #expect(receivedCategories.value == CleanupProfile.developer.categories)
    }

    @Test("empty categories array is rejected as invalidParams")
    func emptyCategoriesRejected() throws {
        let subject = makeHandler(scanner: { _ in [] })
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(true),
                "categories": .array([]),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("categories"))
        }
    }
}

// MARK: - Test capture helpers

// Swift Testing closures need `@Sendable`, and simple Bools/strings/arrays
// aren't cheap to thread-safely capture inline. These tiny reference types
// give tests a shared cell to write into without dragging in `@MainActor`.

private final class CapturedProfileRequest: @unchecked Sendable {
    /// Outer optional distinguishes "scanner never called" (nil) from
    /// "scanner called with nil profile id" (.some(nil)).
    var value: String??
}

private final class CapturedCategories: @unchecked Sendable {
    var value: [String]?
}

private final class CapturedProfile: @unchecked Sendable {
    var value: CleanupProfile?
}
