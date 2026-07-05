import Foundation
import NostrCore

// Convenience signers for NostrClient's higher-level models. The core
// ``EventSigner`` (in NostrCore) signs arbitrary events; these overloads build
// the event from a NostrClient model and sign it through the public
// `sign(_:)` entry point.
extension EventSigner {
    /// Creates and signs a metadata event (kind 0)
    public func signMetadata(_ metadata: UserMetadata) throws -> Event {
        let content = try JSONEncoder().encode(metadata)
        return try sign(
            UnsignedEvent(
                pubkey: publicKey,
                kind: .setMetadata,
                content: String(decoding: content, as: UTF8.self)
            )
        )
    }

    /// Creates and signs a contact list event (kind 3, NIP-02)
    public func signContactList(_ contacts: [Contact]) throws -> Event {
        let tags = contacts.map { Tag.pubkey($0.pubkey, relayURL: $0.relayUrl, petname: $0.petname) }
        return try sign(UnsignedEvent(pubkey: publicKey, kind: .contacts, tags: tags, content: ""))
    }

    /// Creates and signs a contact list event from pubkeys
    public func signContactList(pubkeys: [String]) throws -> Event {
        let contacts = pubkeys.map { Contact(pubkey: $0) }
        return try signContactList(contacts)
    }

    /// Creates and signs a relay list metadata event (kind 10002, NIP-65)
    public func signRelayListMetadata(_ relayList: RelayListMetadata) throws -> Event {
        try sign(
            UnsignedEvent(pubkey: publicKey, kind: .relayListMetadata, rawTags: relayList.toTags(), content: "")
        )
    }

    /// Creates and signs a relay list metadata event from explicit read/write relay URLs (NIP-65).
    /// URLs present in both lists are marked as read+write.
    public func signRelayListMetadata(read: [String] = [], write: [String] = []) throws -> Event {
        let both = Set(read).intersection(write)
        var entries: [RelayListEntry] = []
        for url in read where !both.contains(url) {
            entries.append(RelayListEntry(url: url, usage: .read))
        }
        for url in write where !both.contains(url) {
            entries.append(RelayListEntry(url: url, usage: .write))
        }
        for url in both {
            entries.append(RelayListEntry(url: url, usage: .readWrite))
        }
        return try signRelayListMetadata(RelayListMetadata(entries: entries))
    }

    /// Creates and signs a DM relay list event (kind 10050, NIP-17).
    ///
    /// The event advertises the relays on which the signer wants to receive
    /// private direct messages. Its content is empty; the relays are carried as
    /// `relay` tags.
    public func signDirectMessageRelayList(_ relayList: DirectMessageRelayList) throws -> Event {
        try sign(
            UnsignedEvent(pubkey: publicKey, kind: .directMessageRelayList, rawTags: relayList.toTags(), content: "")
        )
    }

    /// Creates and signs a DM relay list event from relay URLs (kind 10050, NIP-17).
    public func signDirectMessageRelayList(relays: [String]) throws -> Event {
        try signDirectMessageRelayList(DirectMessageRelayList(relays: relays))
    }

    /// Creates and signs a report of a pubkey (kind 1984, NIP-56).
    /// The report type rides on the "p" tag; `reason` becomes the content.
    public func signReport(pubkey: String, type: ReportType, reason: String = "") throws -> Event {
        let tags = [Tag(name: "p", values: [pubkey, type.rawValue])]
        return try sign(
            UnsignedEvent(pubkey: publicKey, kind: .report, rawTags: tags.map(\.rawArray), content: reason)
        )
    }

    /// Creates and signs a report of an event and its author (kind 1984, NIP-56).
    /// The report type rides on the "e" tag; a bare "p" tag names the author.
    public func signReport(event: Event, type: ReportType, reason: String = "") throws -> Event {
        let tags = [
            Tag(name: "e", values: [event.id, type.rawValue]),
            Tag(name: "p", values: [event.pubkey]),
        ]
        return try sign(
            UnsignedEvent(pubkey: publicKey, kind: .report, rawTags: tags.map(\.rawArray), content: reason)
        )
    }

    /// Creates and signs a NIP-51 list event, encrypting private items to the signer's own key
    /// (NIP-44). Content is empty when there are no private items.
    public func signList(_ list: NostrList) throws -> Event {
        let content = try ListItemCipher.encrypt(list.privateItems, using: keyPair)
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: list.kind,
            rawTags: list.publicItems.map(\.rawArray),
            content: content
        )
        return try sign(unsigned)
    }

    /// Reads a NIP-51 list authored by this signer, decrypting its private items.
    /// - Throws: when the content cannot be decrypted with this key.
    public func openList(_ event: Event) throws -> NostrList {
        var list = NostrList(event: event)
        list.privateItems = try ListItemCipher.decrypt(event.content, using: keyPair)
        return list
    }
}
