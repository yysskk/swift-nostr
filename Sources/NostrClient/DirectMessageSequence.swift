import Foundation
import NostrCore

/// A live subscription to the current user's NIP-17 direct messages,
/// delivered already unwrapped and parsed.
///
/// Returned by ``NostrClient/directMessages(limit:)``:
///
/// ```swift
/// for await message in try await client.directMessages() {
///     print("\(message.senderPubkey): \(message.content)")
/// }
/// ```
///
/// Gift wraps that fail to unwrap or parse (foreign or malformed events) are
/// skipped. Use ``NostrClient/subscribeToDirectMessages(limit:)`` for the raw
/// gift-wrap events instead.
///
/// Like ``SubscriptionSequence``, ending iteration, cancelling the consuming
/// task, or calling ``close()`` sends CLOSE to the relays. Single-consumer.
public struct DirectMessageSequence: AsyncSequence, Sendable {
    public typealias Element = DirectMessage

    let base: SubscriptionSequence
    let parser: DirectMessageParser

    /// The subscription ID, usable with ``NostrClient/unsubscribe(subscriptionId:)``.
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

        public mutating func next() async -> DirectMessage? {
            while let item = await base.next() {
                guard case .event(_, let event) = item else { continue }
                guard let message = try? parser.parse(event) else { continue }
                return message
            }
            return nil
        }
    }
}
