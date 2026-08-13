import Foundation
import NostrCore

/// A NIP-23 long-form article (kind 30023; kind 30024 as a draft): Markdown content addressed
/// by a `d` identifier, with display metadata.
/// https://github.com/nostr-protocol/nips/blob/master/23.md
public struct LongFormContent: Sendable, Hashable {
    /// The `d` tag value identifying the article. Editing an article reuses this identifier
    /// so the new event replaces the previous version.
    public var identifier: String

    /// The article title (`title` tag).
    public var title: String?

    /// A short summary of the article (`summary` tag).
    public var summary: String?

    /// A cover image URL for the article (`image` tag).
    public var imageURL: String?

    /// When the article was first published (`published_at` tag, Unix seconds).
    public var publishedAt: Date?

    /// The article's hashtags (`t` tags).
    public var hashtags: [String]

    /// Tags on the event this model does not interpret, preserved so editing an article
    /// does not drop them.
    public var additionalTags: [[String]]

    /// The article body in Markdown.
    public var content: String

    /// Creates a long-form article.
    public init(
        identifier: String,
        title: String? = nil,
        summary: String? = nil,
        imageURL: String? = nil,
        publishedAt: Date? = nil,
        hashtags: [String] = [],
        additionalTags: [[String]] = [],
        content: String = ""
    ) {
        self.identifier = identifier
        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.hashtags = hashtags
        self.additionalTags = additionalTags
        self.content = content
    }

    /// Parses a kind 30023/30024 event; nil for any other kind.
    public init?(event: Event) {
        guard event.kind == .longFormContent || event.kind == .longFormDraft else {
            return nil
        }

        var identifier = ""
        var title: String?
        var summary: String?
        var imageURL: String?
        var publishedAt: Date?
        var hashtags: [String] = []
        var additionalTags: [[String]] = []

        for tag in event.tags {
            guard let name = tag.first else { continue }
            let value = tag.count > 1 ? tag[1] : nil
            switch name {
            case "d":
                identifier = value ?? ""
            case "title":
                title = value
            case "summary":
                summary = value
            case "image":
                imageURL = value
            case "published_at":
                if let value, let seconds = Int64(value) {
                    publishedAt = UnixTimestamp.date(fromSeconds: seconds)
                }
            case "t":
                if let value {
                    hashtags.append(value)
                }
            default:
                additionalTags.append(tag)
            }
        }

        self.init(
            identifier: identifier,
            title: title,
            summary: summary,
            imageURL: imageURL,
            publishedAt: publishedAt,
            hashtags: hashtags,
            additionalTags: additionalTags,
            content: event.content
        )
    }

    /// The full tag array for the article event (d, title, summary, image, published_at, t…, then additionalTags).
    public func toTags() -> [[String]] {
        var tags: [[String]] = [["d", identifier]]
        if let title {
            tags.append(["title", title])
        }
        if let summary {
            tags.append(["summary", summary])
        }
        if let imageURL {
            tags.append(["image", imageURL])
        }
        if let publishedAt {
            tags.append(["published_at", String(UnixTimestamp.seconds(from: publishedAt))])
        }
        for hashtag in hashtags {
            tags.append(["t", hashtag])
        }
        tags.append(contentsOf: additionalTags)
        return tags
    }

    /// The `naddr` addressing this article by `author`.
    ///
    /// Articles are the addressable target, so the coordinate always uses kind 30023
    /// (``Event/Kind/longFormContent``); drafts (kind 30024) are not typically addressed by `naddr`.
    public func naddr(author: String, relays: [String] = []) throws -> NAddr {
        try NAddr(
            identifier: identifier,
            author: author,
            kind: Event.Kind.longFormContent.rawValue,
            relays: relays
        )
    }
}

// MARK: - Long-form Content Helpers
extension Event {
    /// The NIP-23 article carried by a kind 30023/30024 event, if any.
    public var longFormContent: LongFormContent? {
        LongFormContent(event: self)
    }
}
