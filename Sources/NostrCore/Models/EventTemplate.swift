import Foundation

/// The part of an event its author decides: kind, tags, content, and creation time.
///
/// A template carries no public key, id, or signature; ``NostrSigning/sign(_:)-(EventTemplate)``
/// fills in the signer's public key and signs it, so the same template works with a local
/// ``EventSigner`` and a remote NIP-46 signer alike. Static factories build the events the NIPs
/// define, and the properties stay mutable for adjusting a template before it is signed:
///
/// ```swift
/// let note = try await signer.sign(.textNote("gm"))
///
/// var expiring = EventTemplate.textNote("gone in an hour")
/// expiring.tags.append(.expiration(.now.advanced(by: .seconds(3600))))
/// let event = try await remoteSigner.sign(expiring)
/// ```
public struct EventTemplate: Sendable, Hashable {
    /// The event kind (NIP-01).
    public var kind: Event.Kind
    /// The event's tags.
    public var tags: [Tag]
    /// The event's content; its meaning depends on ``kind``.
    public var content: String
    /// When the event was created.
    public var createdAt: Timestamp

    /// Creates a template from its fields.
    /// - Parameters:
    ///   - kind: The event kind.
    ///   - tags: The event's tags.
    ///   - content: The event's content.
    ///   - createdAt: When the event was created; defaults to now.
    public init(kind: Event.Kind, tags: [Tag] = [], content: String = "", createdAt: Timestamp = .now) {
        self.kind = kind
        self.tags = tags
        self.content = content
        self.createdAt = createdAt
    }
}

extension UnsignedEvent {
    /// Creates an unsigned event from `template`, authored under `publicKey`.
    /// - Parameters:
    ///   - template: The event's kind, tags, content, and creation time.
    ///   - publicKey: The author's public key.
    public init(_ template: EventTemplate, publicKey: PublicKey) {
        self.init(
            publicKey: publicKey,
            createdAt: template.createdAt,
            kind: template.kind,
            tags: template.tags,
            content: template.content
        )
    }
}
