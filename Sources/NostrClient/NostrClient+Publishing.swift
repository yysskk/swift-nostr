import Foundation
import NostrCore

// MARK: - Publishing
extension NostrClient {
    /// Publishes a text note
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishTextNote(
        content: String,
        tags: [Tag] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let event = try withSigner { try $0.signTextNote(content: content, tags: tags) }
        let result = try await relayPool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes a reply to an event
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReply(
        to event: Event,
        content: String,
        relayUrl: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let signedEvent = try withSigner { signer -> Event in
            var tags: [Tag] = []

            // Add root and reply markers (NIP-10)
            if let rootTag = event.tags(named: "e").first(where: { $0.values.contains("root") }) {
                tags.append(rootTag)
                tags.append(.event(event.id, relayURL: relayUrl, marker: .reply))
            } else {
                // This is a reply to a root event
                tags.append(.event(event.id, relayURL: relayUrl, marker: .root))
            }

            // Add p tag for the author we're replying to
            tags.append(.pubkey(event.pubkey))

            let unsigned = UnsignedEvent(
                pubkey: signer.publicKey,
                kind: .textNote,
                tags: tags,
                content: content
            )

            return try signer.sign(unsigned)
        }
        let result = try await relayPool.publish(signedEvent, strategy: strategy)
        return PublishedEvent(event: signedEvent, result: result)
    }

    /// Publishes user metadata
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishMetadata(
        _ metadata: UserMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let event = try withSigner { try $0.signMetadata(metadata) }
        let result = try await relayPool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes a reaction to an event
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReaction(
        to event: Event,
        content: String = "+",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let reaction = try withSigner { try $0.signReaction(to: event, content: content) }
        let result = try await relayPool.publish(reaction, strategy: strategy)
        return PublishedEvent(event: reaction, result: result)
    }

    /// Publishes a repost
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRepost(
        of event: Event,
        relayUrl: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let repost = try withSigner { try $0.signRepost(of: event, relayUrl: relayUrl) }
        let result = try await relayPool.publish(repost, strategy: strategy)
        return PublishedEvent(event: repost, result: result)
    }

    /// Publishes a deletion request
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDeletion(
        eventIds: [String],
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let deletion = try withSigner { try $0.signDeletion(eventIds: eventIds, reason: reason) }
        let result = try await relayPool.publish(deletion, strategy: strategy)
        return PublishedEvent(event: deletion, result: result)
    }

    /// Publishes a raw signed event.
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publish(_ event: Event, strategy: PublishStrategy? = nil) async throws -> PublishResult {
        try await relayPool.publish(event, strategy: strategy)
    }
}
