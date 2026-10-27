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

    /// When the article was first published (`published_at` tag). Editing an article keeps this
    /// value while the event's `created_at` moves forward.
    public var publishedAt: Timestamp?

    /// The article's hashtags (`t` tags).
    public var hashtags: [String]

    /// Tags on the event this model does not interpret, preserved so editing an article
    /// does not drop them.
    public var additionalTags: [Tag]

    /// The article body in Markdown.
    public var content: String

    /// Creates a long-form article.
    public init(
        identifier: String,
        title: String? = nil,
        summary: String? = nil,
        imageURL: String? = nil,
        publishedAt: Timestamp? = nil,
        hashtags: [String] = [],
        additionalTags: [Tag] = [],
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
        var publishedAt: Timestamp?
        var hashtags: [String] = []
        var additionalTags: [Tag] = []

        for tag in event.tags {
            let value = tag.primaryValue
            switch tag.name {
            case .identifier:
                identifier = value ?? ""
            case "title":
                title = value
            case "summary":
                summary = value
            case "image":
                imageURL = value
            case "published_at":
                if let value, let seconds = Int64(value) {
                    publishedAt = Timestamp(rawValue: seconds)
                }
            case .hashtag:
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
    public var tags: [Tag] {
        var tags: [Tag] = [.identifier(identifier)]
        if let title {
            tags.append(Tag(name: "title", values: [title]))
        }
        if let summary {
            tags.append(Tag(name: "summary", values: [summary]))
        }
        if let imageURL {
            tags.append(Tag(name: "image", values: [imageURL]))
        }
        if let publishedAt {
            tags.append(Tag(name: "published_at", values: [publishedAt.description]))
        }
        for hashtag in hashtags {
            tags.append(.hashtag(hashtag))
        }
        tags.append(contentsOf: additionalTags)
        return tags
    }

    /// The `naddr` addressing this article by `author`.
    ///
    /// Articles are the addressable target, so the coordinate always uses kind 30023
    /// (``Event/Kind/longFormContent``); drafts (kind 30024) are not typically addressed by `naddr`.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical form is longer
    ///   than 255 bytes.
    public func naddr(author: PublicKey, relays: [RelayURL] = []) throws(NIP19Entity.Error) -> NAddr {
        try NAddr(
            identifier: identifier,
            author: author,
            kind: .longFormContent,
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
