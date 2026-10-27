import Foundation
import NostrCore

/// A live subscription to the current user's NIP-17 direct messages,
/// delivered already unwrapped and parsed.
///
/// Returned by ``NostrMessaging/subscribe(limit:)``:
///
/// ```swift
/// for try await message in try await client.messages.subscribe() {
///     print("\(message.senderPublicKey): \(message.content)")
/// }
/// ```
///
/// Gift wraps that are not readable messages for this signer — sealed to someone else, or
/// malformed — are skipped, since a gift-wrap stream carries everyone's messages. A signer that
/// fails to *attempt* the read is different: with a remote NIP-46 signer every unwrap is a relay
/// round-trip, so a timeout, a disconnect, or a refused request throws out of the iteration
/// instead of silently dropping messages. Resubscribe to resume. Use
/// ``NostrMessaging/giftWraps(limit:)`` for the raw gift-wrap events instead.
///
/// Like ``SubscriptionSequence``, ending iteration, cancelling the consuming
/// task, or calling ``close()`` sends CLOSE to the relays. Single-consumer.
public struct DirectMessageSequence: AsyncSequence, Sendable {
    public typealias Element = DirectMessage

    let base: SubscriptionSequence
    let parser: DirectMessageParser

    /// The messages of `payloads`: the same subscription and parser, reading each gift wrap as a
    /// message only, so a reaction or file message is skipped before it is parsed.
    init(messagesOf payloads: DirectMessagePayloadSequence) {
        self.base = payloads.base
        self.parser = payloads.parser
    }

    /// The subscription ID, usable with ``NostrSubscriptionsAPI/unsubscribe(id:)``.
    public var id: SubscriptionID { base.id }

    /// The relays that accepted the REQ.
    public var expectedRelays: Set<RelayURL> { base.expectedRelays }

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

        public mutating func next() async throws -> DirectMessage? {
            while let item = await base.next() {
                guard case .event(_, let event) = item else { continue }
                if let message = try await parser.parseIfReadable(event) {
                    return message
                }
            }
            return nil
        }
    }
}
