import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Sample JSON Fixtures

private let validMoleJSON = """
{
    "items": [
        {
            "id": "chrome_cache_001",
            "name": "Chrome Browser Cache",
            "path": "/Users/dev/Library/Caches/Google/Chrome",
            "size": 1500000000,
            "category": "browser_cache",
            "confidence": 98,
            "explanation": "Chrome browser cache — safe to delete, regenerates on use",
            "source": "Google Chrome",
            "source_bundle_id": "com.google.Chrome",
            "last_accessed": "2026-01-15T10:30:00Z",
            "tags": ["browser", "cache"],
            "regenerates": true,
            "regenerate_command": null
        },
        {
            "id": "docker_images_001",
            "name": "Docker Images",
            "path": "/Users/dev/.docker/images",
            "size": 8000000000,
            "category": "docker",
            "confidence": 85,
            "explanation": "Docker images — may contain important builds",
            "source": "Docker Desktop",
            "source_bundle_id": "com.docker.docker",
            "tags": ["dev", "docker"],
            "regenerates": false
        },
        {
            "id": "safari_history_001",
            "name": "Safari Browsing History",
            "path": "/Users/dev/Library/Safari/History.db",
            "size": 50000000,
            "category": "browser_data",
            "confidence": 90,
            "explanation": "Browser history and saved data",
            "source": "Safari",
            "source_bundle_id": "com.apple.Safari"
        }
    ],
    "scan_duration": 3.5,
    "total_size": 9550000000
}
"""

private let minimalItemJSON = """
{
    "items": [
        {
            "id": "minimal_001",
            "path": "/tmp/test/file.txt"
        }
    ]
}
"""

private let mixedValidInvalidJSON = """
{
    "items": [
        {
            "id": "good_001",
            "path": "/tmp/good.txt",
            "category": "temp_files",
            "size": 1000
        },
        {
            "id": "bad_001",
            "path": ""
        },
        {
            "id": "good_002",
            "path": "/tmp/also_good.txt",
            "category": "system_logs",
            "size": 2000
        }
    ]
}
"""

@Suite("MoleOutputParser")
struct MoleOutputParserTests {

    @Test("Parses complete Mole JSON with all fields")
    func parsesCompleteMoleJSON() throws {
        let results = try MoleOutputParser.parse(validMoleJSON)
        #expect(results.count == 3)

        // Chrome cache — safe
        let chrome = results[0]
        #expect(chrome.id == "chrome_cache_001")
        #expect(chrome.name == "Chrome Browser Cache")
        #expect(chrome.size == 1_500_000_000)
        #expect(chrome.safety == .safe)
        #expect(chrome.confidence == 98)
        #expect(chrome.source.bundleID == "com.google.Chrome")
        #expect(chrome.regenerates == true)
        #expect(chrome.category == "browser_cache")

        // Docker — review
        let docker = results[1]
        #expect(docker.id == "docker_images_001")
        #expect(docker.safety == .review)
        #expect(docker.regenerates == false)

        // Browser data — protected
        let safari = results[2]
        #expect(safari.id == "safari_history_001")
        #expect(safari.safety == .protected_)
    }

    @Test("Handles minimal items with only required fields")
    func parsesMinimalItems() throws {
        let results = try MoleOutputParser.parse(minimalItemJSON)
        #expect(results.count == 1)

        let item = results[0]
        #expect(item.id == "minimal_001")
        #expect(item.path == "/tmp/test/file.txt")
        #expect(item.name == "file.txt") // derived from path
        #expect(item.size == 0) // default
        #expect(item.confidence == 80) // default
        #expect(item.explanation == "Detected by Mole scanner") // default
        #expect(item.category == "unknown") // default
        #expect(item.safety == .review) // unknown → review
    }

    @Test("Skips items with empty path, continues parsing")
    func skipsInvalidItemsContinues() throws {
        let results = try MoleOutputParser.parse(mixedValidInvalidJSON)
        #expect(results.count == 2) // bad_001 skipped
        #expect(results[0].id == "good_001")
        #expect(results[1].id == "good_002")
    }

    @Test("Throws invalidJSON for garbage input")
    func throwsForGarbageInput() {
        #expect(throws: MoleParseError.self) {
            try MoleOutputParser.parse("not json at all")
        }
    }

    @Test("Throws invalidJSON for empty string")
    func throwsForEmptyString() {
        #expect(throws: MoleParseError.self) {
            try MoleOutputParser.parse("")
        }
    }

    @Test("Skips items missing required JSON fields without failing entire parse")
    func skipsMissingRequiredFields() throws {
        let json = """
        {
            "items": [
                { "id": "good", "path": "/tmp/good.txt", "category": "temp_files" },
                { "name": "no id or path" },
                { "id": "also_good", "path": "/tmp/ok.txt" },
                42,
                { "id": "still_good", "path": "/tmp/fine.txt" }
            ]
        }
        """
        let results = try MoleOutputParser.parse(json)
        #expect(results.count == 3)
        #expect(results[0].id == "good")
        #expect(results[1].id == "also_good")
        #expect(results[2].id == "still_good")
    }

    @Test("Parses empty items array")
    func parsesEmptyItemsArray() throws {
        let json = """
        { "items": [] }
        """
        let results = try MoleOutputParser.parse(json)
        #expect(results.isEmpty)
    }

    @Test("Parses ISO 8601 dates")
    func parsesISO8601Dates() throws {
        let results = try MoleOutputParser.parse(validMoleJSON)
        let chrome = results[0]
        #expect(chrome.lastAccessed != nil)

        // Docker has no last_accessed
        let docker = results[1]
        #expect(docker.lastAccessed == nil)
    }

    @Test("Tags are preserved when present")
    func tagsPreserved() throws {
        let results = try MoleOutputParser.parse(validMoleJSON)
        #expect(results[0].tags == ["browser", "cache"])
        #expect(results[1].tags == ["dev", "docker"])
    }

    @Test("Missing tags default to empty array")
    func missingTagsDefaultEmpty() throws {
        let results = try MoleOutputParser.parse(minimalItemJSON)
        #expect(results[0].tags.isEmpty)
    }
}

@Suite("Category Safety Mapping")
struct CategorySafetyMappingTests {

    @Test("Safe categories")
    func safeCategories() {
        let safeCategories = [
            "browser_cache", "system_cache", "system_logs",
            "temp_files", "trash", "installers",
            "empty_files", "broken_symlinks",
        ]
        for category in safeCategories {
            #expect(MoleOutputParser.safetyLevel(for: category) == .safe,
                    "Expected '\(category)' to be safe")
        }
    }

    @Test("Review categories")
    func reviewCategories() {
        let reviewCategories = ["dev_artifacts", "docker", "homebrew", "similar_images"]
        for category in reviewCategories {
            #expect(MoleOutputParser.safetyLevel(for: category) == .review,
                    "Expected '\(category)' to be review")
        }
    }

    @Test("Protected categories")
    func protectedCategories() {
        #expect(MoleOutputParser.safetyLevel(for: "browser_data") == .protected_)
    }

    @Test("Unknown categories default to review")
    func unknownDefaultsToReview() {
        #expect(MoleOutputParser.safetyLevel(for: "totally_new_category") == .review)
        #expect(MoleOutputParser.safetyLevel(for: "") == .review)
        #expect(MoleOutputParser.safetyLevel(for: "future_scan_type") == .review)
    }
}
