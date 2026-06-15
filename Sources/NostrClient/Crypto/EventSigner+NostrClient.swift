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
}
