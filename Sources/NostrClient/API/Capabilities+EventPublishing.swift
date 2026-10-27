import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrEventPublishing {
    /// Signs `template` with the configured signer and publishes it along `route`, waiting for the
    /// pool config's ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrEventPublishing/publish(_:route:strategy:)-(EventTemplate,_,_)``.
    /// - Parameters:
    ///   - template: The event to sign and publish.
    ///   - route: The relays to publish to (default: the whole pool).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publish(_ template: EventTemplate, route: RelayRoute = .pool) async throws -> PublishedEvent {
        try await publish(template, route: route, strategy: nil)
    }

    /// Publishes an already-signed event along `route`, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrEventPublishing/publish(_:route:strategy:)-(Event,_,_)``.
    /// - Parameters:
    ///   - event: The already-signed event to publish.
    ///   - route: The relays to publish to (default: the whole pool).
    /// - Returns: The per-relay outcome of the publish, keyed by relay URL.
    @discardableResult
    public func publish(_ event: Event, route: RelayRoute = .pool) async throws -> PublishResult {
        try await publish(event, route: route, strategy: nil)
    }
}

// MARK: - Conveniences

extension NostrEventPublishing {
    /// Signs and publishes a text note (kind 1) to the whole pool.
    /// - Parameters:
    ///   - content: The note's text.
    ///   - tags: Tags to attach to the note.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishTextNote(
        content: String,
        tags: [Tag] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.textNote(content, tags: tags), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a NIP-10 reply to `event` to the whole pool, built by
    /// ``EventTemplate/reply(to:content:relayURL:)``.
    /// - Parameters:
    ///   - event: The event being replied to; its thread root and author are carried over. A
    ///     relay hint on a root in NIP-10's positional form is carried over only when it is a
    ///     valid relay URL.
    ///   - content: The reply's text.
    ///   - relayURL: The relay where the replied-to event can be found, recorded in the
    ///     NIP-10 `e` tag.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReply(
        to event: Event,
        content: String,
        relayURL: RelayURL? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.reply(to: event, content: content, relayURL: relayURL), route: .pool, strategy: strategy)
    }

    /// Signs and publishes user metadata (kind 0) to the whole pool.
    /// - Parameters:
    ///   - metadata: The profile to publish.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishMetadata(
        _ metadata: UserMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.metadata(metadata), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a reaction (kind 7) to `event` to the whole pool.
    /// - Parameters:
    ///   - event: The event being reacted to.
    ///   - content: The reaction: `"+"` for a like, `"-"` for a dislike, or an emoji.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReaction(
        to event: Event,
        content: String = "+",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.reaction(to: event, content: content), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a repost (kind 6) of `event` to the whole pool.
    /// - Parameters:
    ///   - event: The event being reposted.
    ///   - relayURL: The relay where the reposted event can be found, recorded in the `e` tag.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRepost(
        of event: Event,
        relayURL: RelayURL? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.repost(of: event, relayURL: relayURL), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a deletion request (kind 5, NIP-09) for events the signer authored to the
    /// whole pool.
    /// - Parameters:
    ///   - eventIDs: The ids of the events to delete.
    ///   - reason: Why the events are deleted.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDeletion(
        eventIDs: [EventID],
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.deletion(of: eventIDs, reason: reason), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a report of a public key (kind 1984, NIP-56) to the whole pool.
    /// - Parameters:
    ///   - target: The public key being reported.
    ///   - type: Why the public key is reported.
    ///   - reason: Free-text detail.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReport(
        publicKey target: PublicKey,
        type: ReportType,
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.report(target, type: type, reason: reason), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a report of an event and its author (kind 1984, NIP-56) to the whole pool.
    /// - Parameters:
    ///   - event: The event being reported.
    ///   - type: Why the event is reported.
    ///   - reason: Free-text detail.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReport(
        event: Event,
        type: ReportType,
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.report(event, type: type, reason: reason), route: .pool, strategy: strategy)
    }

    /// Signs and publishes a NIP-23 long-form article to the whole pool; the same identifier
    /// replaces the previous version.
    /// - Parameters:
    ///   - article: The article to publish; its `identifier` addresses the replaceable event.
    ///   - draft: Publishes as a kind 30024 draft instead of a kind 30023 article.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishLongFormContent(
        _ article: LongFormContent,
        draft: Bool = false,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.longFormContent(article, draft: draft), route: .pool, strategy: strategy)
    }
}
