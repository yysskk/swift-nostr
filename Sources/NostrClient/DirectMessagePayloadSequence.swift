import Foundation
import NostrCore

/// A live subscription to the current user's NIP-17 gift-wrap stream, delivering each gift
/// wrap already unwrapped and classified as a ``DirectMessagePayload`` — a message or a
/// reaction to one.
///
/// Returned by ``NostrMessagesAPI/payloads(limit:)``:
///
/// ```swift
/// for try await payload in try await client.messages.payloads() {
///     switch payload {
///     case .message(let message): print("\(message.senderPubkey): \(message.content)")
///     case .reaction(let reaction): print("\(reaction.senderPubkey) reacted \(reaction.content)")
///     }
/// }
/// ```
///
/// Gift wraps that are not readable payloads for this signer — sealed to someone else, malformed,
/// or carrying an inner kind that is none of the three — are skipped. A signer that fails to
/// *attempt* the read is different: with a remote NIP-46 signer every unwrap is a relay round-trip,
/// so a timeout, a disconnect, or a refused request throws out of the iteration instead of silently
/// dropping payloads. Resubscribe to resume. Use ``NostrMessagesAPI/subscribe(limit:)`` for
/// messages only, or ``NostrMessagesAPI/giftWraps(limit:)`` for the raw gift-wrap events.
///
/// Like ``SubscriptionSequence``, ending iteration, cancelling the consuming task, or calling
/// ``close()`` sends CLOSE to the relays. Single-consumer.
public struct DirectMessagePayloadSequence: AsyncSequence, Sendable {
    public typealias Element = DirectMessagePayload

    let base: SubscriptionSequence
    let parser: DirectMessageParser

    /// The subscription ID, usable with ``NostrSubscriptionsAPI/unsubscribe(subscriptionId:)``.
    public var id: String { base.id }

    /// The relays that accepted the REQ.
    public var expectedRelays: Set<URL> { base.expectedRelays }

    /// Closes the subscription: sends CLOSE to the relays and ends iteration.
    public func close() async {
        await base.close()
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
                if let payload = try await parser.parsePayloadIfReadable(event) {
                    return payload
                }
            }
            return nil
        }
    }
}
