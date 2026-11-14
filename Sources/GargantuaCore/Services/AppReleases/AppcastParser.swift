import Foundation

/// One `<item>` of a Sparkle appcast.
public struct AppcastItem: Sendable, Equatable {
    public var title: String?
    /// `sparkle:shortVersionString`.
    public var shortVersion: String?
    /// `sparkle:version`.
    public var version: String?
    public var minimumSystemVersion: String?
    public var maximumSystemVersion: String?
    /// `sparkle:channel`; stable items have none.
    public var channel: String?
    public var isCriticalUpdate = false
    /// `sparkle:informationalUpdate` is present: nothing to download.
    public var isInformationalUpdate = false
    public var enclosureURL: String?
    public var enclosureLength: Int64?
    public var enclosureType: String?
    public var edSignature: String?
    public var releaseNotesURL: String?
    public var link: String?
    public var pubDate: String?

    public init() {}
}

public enum AppcastParser {
    public struct ParseError: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { "Malformed appcast: \(message)" }
    }

    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError(message: parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var depthInDeltas = 0
        private var enclosureTaken = false
        // Attribute-form versions, used when no child element supplies them.
        private var enclosureShort: String?
        private var enclosureBuild: String?
        private var childShort: String?
        private var childBuild: String?

        func parser(
            _: XMLParser, didStartElement name: String, namespaceURI _: String?,
            qualifiedName _: String?, attributes attrs: [String: String]
        ) {
            text = ""
            if current == nil {
                if name == "item" {
                    current = AppcastItem()
                    enclosureTaken = false
                    enclosureShort = nil
                    enclosureBuild = nil
                    childShort = nil
                    childBuild = nil
                }
                return
            }
            if name == "sparkle:deltas" { depthInDeltas += 1 }
            guard depthInDeltas == 0 else { return }
            switch name {
            case "enclosure" where !enclosureTaken:
                let os = attrs["sparkle:os"]?.lowercased()
                guard os == nil || os == "macos" else { return }
                enclosureTaken = true
                current?.enclosureURL = attrs["url"]
                current?.enclosureLength = attrs["length"].flatMap { Int64($0) }
                current?.enclosureType = attrs["type"]
                current?.edSignature = attrs["sparkle:edSignature"]
                enclosureShort = attrs["sparkle:shortVersionString"]
                enclosureBuild = attrs["sparkle:version"]
            case "sparkle:informationalUpdate":
                current?.isInformationalUpdate = true
            case "sparkle:criticalUpdate":
                current?.isCriticalUpdate = true
            default:
                break
            }
        }

        let textFields: [String: WritableKeyPath<AppcastItem, String?>] = [
            "title": \.title,
            "link": \.link,
            "pubDate": \.pubDate,
            "sparkle:minimumSystemVersion": \.minimumSystemVersion,
            "sparkle:maximumSystemVersion": \.maximumSystemVersion,
            "sparkle:channel": \.channel,
            "sparkle:releaseNotesLink": \.releaseNotesURL,
        ]

        func parser(_: XMLParser, foundCharacters string: String) { text += string }

        func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(bytes: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_: XMLParser, didEndElement name: String, namespaceURI _: String?, qualifiedName _: String?) {
            guard current != nil else { return }
            if name == "sparkle:deltas" {
                depthInDeltas -= 1
                return
            }
            guard depthInDeltas == 0 else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let present: String? = value.isEmpty ? nil : value
            if name == "item" {
                current?.shortVersion = childShort ?? enclosureShort
                current?.version = childBuild ?? enclosureBuild
                if let item = current { items.append(item) }
                current = nil
            } else if name == "sparkle:shortVersionString" {
                childShort = present
            } else if name == "sparkle:version" {
                childBuild = present
            } else if name == "sparkle:fullReleaseNotesLink" {
                if current?.releaseNotesURL == nil { current?.releaseNotesURL = present }
            } else if let path = textFields[name] {
                current?[keyPath: path] = present
            }
            text = ""
        }
    }
}
