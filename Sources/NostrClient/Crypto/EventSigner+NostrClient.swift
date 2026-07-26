import Foundation
import NostrCore

// Convenience signers for NostrClient's higher-level models. The core
// ``EventSigner`` (in NostrCore) signs arbitrary events; these overloads build
// the event from a NostrClient model and sign it through the public
// `sign(_:)` entry point.
extension EventSigner {
    /// Creates and signs a metadata event (kind 0)
    public func signMetadata(_ metadata: UserMetadata) throws -> Event {
        try sign(.metadata(pubkey: publicKey, metadata))
    }

    /// Creates and signs a contact list event (kind 3, NIP-02)
    public func signContactList(_ contacts: [Contact]) throws -> Event {
        let tags = contacts.map { Tag.pubkey($0.pubkey, relayURL: $0.relayURL, petname: $0.petname) }
        return try sign(UnsignedEvent(pubkey: publicKey, kind: .contacts, tags: tags, content: ""))
    }

    /// Creates and signs a contact list event from pubkeys
    public func signContactList(pubkeys: [String]) throws -> Event {
        let contacts = pubkeys.map { Contact(pubkey: $0) }
        return try signContactList(contacts)
    }

    /// Creates and signs a relay list metadata event (kind 10002, NIP-65)
    public func signRelayListMetadata(_ relayList: RelayListMetadata) throws -> Event {
        try sign(.relayListMetadata(pubkey: publicKey, relayList))
    }

    /// Creates and signs a relay list metadata event from explicit read/write relay URLs (NIP-65).
    /// URLs present in both lists are marked as read+write.
    public func signRelayListMetadata(read: [String] = [], write: [String] = []) throws -> Event {
        try signRelayListMetadata(RelayListMetadata(read: read, write: write))
    }

    /// Creates and signs a DM relay list event (kind 10050, NIP-17).
    ///
    /// The event advertises the relays on which the signer wants to receive
    /// private direct messages. Its content is empty; the relays are carried as
    /// `relay` tags.
    public func signDirectMessageRelayList(_ relayList: DirectMessageRelayList) throws -> Event {
        try sign(.directMessageRelayList(pubkey: publicKey, relayList))
    }

    /// Creates and signs a DM relay list event from relay URLs (kind 10050, NIP-17).
    public func signDirectMessageRelayList(relays: [String]) throws -> Event {
        try signDirectMessageRelayList(DirectMessageRelayList(relays: relays))
    }

    /// Creates and signs a report of a pubkey (kind 1984, NIP-56).
    /// The report type rides on the "p" tag; `reason` becomes the content.
    public func signReport(pubkey: String, type: ReportType, reason: String = "") throws -> Event {
        try sign(.report(pubkey: publicKey, target: pubkey, type: type, reason: reason))
    }

    /// Creates and signs a report of an event and its author (kind 1984, NIP-56).
    /// The report type rides on the "e" tag; a bare "p" tag names the author.
    public func signReport(event: Event, type: ReportType, reason: String = "") throws -> Event {
        try sign(.report(pubkey: publicKey, event: event, type: type, reason: reason))
    }

    /// Creates and signs a long-form article (kind 30023, or 30024 when `draft`; NIP-23).
    /// When `publishedAt` is nil it is set to the current time (first-publication time per the spec);
    /// it is preserved verbatim on later edits.
    public func signLongFormContent(_ article: LongFormContent, draft: Bool = false) throws -> Event {
        try sign(.longFormContent(pubkey: publicKey, article, draft: draft))
    }

    /// Creates and signs a NIP-51 list event, encrypting private items to the signer's own key
    /// (NIP-44). Content is empty when there are no private items.
    public func signList(_ list: NostrList) throws -> Event {
        try sign(.list(pubkey: publicKey, list, encryptedContent: sealPrivateItems(list.privateItems)))
    }

    /// Reads a NIP-51 list authored by this signer, decrypting its private items.
    /// - Throws: when the content cannot be decrypted with this key.
    public func openList(_ event: Event) throws -> NostrList {
        var list = NostrList(event: event)
        list.privateItems = try openPrivateItems(event.content)
        return list
    }

    /// Creates and signs a NIP-51 set event: the `d` identifier, presentation metadata, and
    /// public items as tags, with private items NIP-44-encrypted to the signer's own key in
    /// the content. Content is empty when there are no private items.
    public func signSet(_ set: NostrListSet) throws -> Event {
        try sign(.set(pubkey: publicKey, set, encryptedContent: sealPrivateItems(set.privateItems)))
    }

    /// Reads a NIP-51 set authored by this signer, decrypting its private items.
    /// - Throws: when the event has no `d` identifier, or its content cannot be decrypted
    ///   with this key.
    public func openSet(_ event: Event) throws -> NostrListSet {
        var set = try NostrListSet(event: event)
        set.privateItems = try openPrivateItems(event.content)
        return set
    }

    /// Seals a list's or set's private items to this signer's own key, or returns empty content
    /// when there are none.
    private func sealPrivateItems(_ items: [Tag]) throws -> String {
        guard let json = try ListItemCipher.plaintext(items) else { return "" }
        return try nip44Encrypt(json, to: publicKey)
    }

    /// Opens the self-encrypted private items of a list or set event (empty content → []).
    private func openPrivateItems(_ content: String) throws -> [Tag] {
        guard !content.isEmpty else { return [] }
        return try ListItemCipher.items(fromJSON: nip44Decrypt(content, from: publicKey))
    }
}
