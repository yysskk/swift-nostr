import Foundation
import NostrCore

/// A live subscription to the current user's NIP-17 gift-wrap stream, delivering each gift
/// wrap already unwrapped and classified as a ``DirectMessagePayload`` — a message, a reaction
/// to one, or a file.
///
/// Returned by ``NostrMessaging/subscribe(limit:)``:
///
/// ```swift
/// for try await payload in try await client.messages.subscribe() {
///     switch payload {
///     case .message(let message): print("\(message.senderPublicKey): \(message.content)")
///     case .reaction(let reaction): print("\(reaction.senderPublicKey) reacted \(reaction.content)")
///     case .file(let file): print("\(file.senderPublicKey) sent \(file.url)")
///     }
/// }
/// ```
///
/// Gift wraps that are not readable payloads for this signer — sealed to someone else, malformed,
/// or carrying an inner kind that is none of the three — are skipped. A signer that fails to
/// *attempt* the read is different: with a remote NIP-46 signer every unwrap is a relay round-trip,
/// so a timeout, a disconnect, or a refused request throws out of the iteration instead of silently
/// dropping payloads. Resubscribe to resume. Iterate ``messages`` for messages only, or
/// ``giftWraps`` for the raw gift-wrap events.
///
/// Like ``SubscriptionSequence``, ending iteration, cancelling the consuming task, or calling
/// ``close()`` sends CLOSE to the relays.
///
/// - Important: The sequence is single-consumer: create one iterator — on this sequence, on
///   ``messages``, or on ``giftWraps``, not more. Multiple iterators race for elements.
public struct DirectMessagePayloadSequence: AsyncSequence, Sendable {
    public typealias Element = DirectMessagePayload

    let base: SubscriptionSequence
    let parser: DirectMessageParser

    /// Creates a sequence that unwraps the gift wraps `subscription` yields with `parser` — for a
    /// stub ``NostrMessaging`` conformer; the client builds its own.
    /// - Parameters:
    ///   - subscription: The gift-wrap subscription; its non-event items are skipped.
    ///   - parser: Opens each gift wrap, as the recipient it is bound to.
    public init(subscription: SubscriptionSequence, parser: DirectMessageParser) {
        self.base = subscription
        self.parser = parser
    }

    /// The subscription ID, usable with ``NostrSubscriptionsAPI/unsubscribe(id:)``.
    public var id: SubscriptionID { base.id }

    /// The relays that accepted the REQ.
    public var expectedRelays: Set<RelayURL> { base.expectedRelays }

    /// Closes the subscription: sends CLOSE to the relays and ends iteration.
    public func close() async {
        await base.close()
    }

    /// A view of this subscription that yields only the private direct messages (kind 14),
    /// skipping reactions and file messages before they are parsed.
    public var messages: DirectMessageSequence {
        DirectMessageSequence(messagesOf: self)
    }

    /// The underlying subscription, yielding the gift wraps (kind 1059) still sealed; open each
    /// event with ``NostrMessaging/open(_:)``.
    public var giftWraps: SubscriptionSequence {
        base
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), parser: parser)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: SubscriptionSequence.AsyncIterator
        let parser: DirectMessageParser

        public mutating func next() async throws -> DirectMessagePayload? {
            while let item = await base.next() {
                guard case .event(_, let event) = item else { continue }
                if let payload = try await parser.openIfReadable(event) {
                    return payload
                }
            }
            return nil
        }
    }
}
