import Foundation
import NostrCore

// Builders for NostrClient's higher-level models, mirroring the NostrCore builders: each takes
// the author's public key rather than a signer, so the local ``EventSigner`` conveniences and the
// ``NostrSigning``-based client helpers build the identical event.
//
// The NIP-51 list and set builders take their private items already encrypted, because sealing
// them goes through the signer — synchronously for a local key, over a relay round-trip for a
// remote one.
extension UnsignedEvent {
    /// A metadata event (kind 0).
    package static func metadata(publicKey: PublicKey, _ metadata: UserMetadata) throws -> UnsignedEvent {
        let content = try JSONEncoder().encode(metadata)
        return UnsignedEvent(
            publicKey: publicKey, kind: .setMetadata, content: String(decoding: content, as: UTF8.self))
    }

    /// A relay list metadata event (kind 10002, NIP-65).
    package static func relayListMetadata(publicKey: PublicKey, _ relayList: RelayListMetadata) -> UnsignedEvent {
        UnsignedEvent(publicKey: publicKey, kind: .relayListMetadata, tags: relayList.tags, content: "")
    }

    /// A DM relay list event (kind 10050, NIP-17), advertising where the author receives
    /// private direct messages. Its content is empty; the relays are carried as `relay` tags.
    package static func directMessageRelayList(
        publicKey: PublicKey, _ relayList: DirectMessageRelayList
    ) -> UnsignedEvent {
        UnsignedEvent(publicKey: publicKey, kind: .directMessageRelayList, tags: relayList.tags, content: "")
    }

    /// A report of `target` (kind 1984, NIP-56). The report type rides on the "p" tag;
    /// `reason` becomes the content.
    package static func report(
        publicKey: PublicKey, target: PublicKey, type: ReportType, reason: String
    ) -> UnsignedEvent {
        UnsignedEvent(
            publicKey: publicKey,
            kind: .report,
            tags: [Tag(name: "p", values: [target.hex, type.rawValue])],
            content: reason
        )
    }

    /// A report of an event and its author (kind 1984, NIP-56). The report type rides on the
    /// "e" tag; a bare "p" tag names the author.
    package static func report(
        publicKey: PublicKey, event: Event, type: ReportType, reason: String
    ) -> UnsignedEvent {
        UnsignedEvent(
            publicKey: publicKey,
            kind: .report,
            tags: [
                Tag(name: "e", values: [event.id.hex, type.rawValue]),
                .publicKey(event.publicKey),
            ],
            content: reason
        )
    }

    /// A long-form article (kind 30023, or 30024 when `draft`; NIP-23).
    ///
    /// When `publishedAt` is nil it is set to the current time (first-publication time per the
    /// spec); it is preserved verbatim on later edits.
    package static func longFormContent(
        publicKey: PublicKey, _ article: LongFormContent, draft: Bool
    ) -> UnsignedEvent {
        var article = article
        if article.publishedAt == nil {
            article.publishedAt = .now
        }
        return UnsignedEvent(
            publicKey: publicKey,
            kind: draft ? .longFormDraft : .longFormContent,
            tags: article.tags,
            content: article.content
        )
    }

    /// A NIP-51 list event whose private items are already sealed into `encryptedContent`.
    package static func list(publicKey: PublicKey, _ list: NostrList, encryptedContent: String) -> UnsignedEvent {
        UnsignedEvent(
            publicKey: publicKey,
            kind: list.kind,
            tags: list.publicItems,
            content: encryptedContent
        )
    }

    /// A NIP-51 set event whose private items are already sealed into `encryptedContent`: the `d`
    /// identifier, presentation metadata, and public items as tags.
    package static func set(publicKey: PublicKey, _ set: NostrListSet, encryptedContent: String) -> UnsignedEvent {
        var tags: [Tag] = [.identifier(set.identifier)]
        if let title = set.title {
            tags.append(Tag(name: "title", values: [title]))
        }
        if let imageURL = set.imageURL {
            tags.append(Tag(name: "image", values: [imageURL]))
        }
        if let description = set.description {
            tags.append(Tag(name: "description", values: [description]))
        }
        // Drop any reserved metadata tags a caller may have left in publicItems so they are
        // never emitted twice alongside the dedicated properties above.
        tags.append(contentsOf: set.publicItems.filter { !NostrListSet.reservedTagNames.contains($0.name) })

        return UnsignedEvent(
            publicKey: publicKey,
            kind: set.kind,
            tags: tags,
            content: encryptedContent
        )
    }
}
