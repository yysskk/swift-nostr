import NostrCore

// MARK: - Long-form Content (NIP-23)
extension EventTemplate {
    /// A long-form article (kind 30023), or a draft (kind 30024): the article's metadata as tags
    /// and its Markdown body as the content.
    ///
    /// When the article's `publishedAt` is nil it is set to the current time, the first-publication
    /// time the spec asks for; a value already set is kept verbatim, so later edits preserve it.
    /// https://github.com/nostr-protocol/nips/blob/master/23.md
    /// - Parameters:
    ///   - article: The article; its `identifier` addresses the replaceable event.
    ///   - draft: Whether to build a kind 30024 draft instead of a kind 30023 article.
    /// - Returns: The template for the article.
    public static func longFormContent(_ article: LongFormContent, draft: Bool = false) -> EventTemplate {
        var article = article
        if article.publishedAt == nil {
            article.publishedAt = .now
        }
        return EventTemplate(
            kind: draft ? .longFormDraft : .longFormContent,
            tags: article.tags,
            content: article.content
        )
    }
}
