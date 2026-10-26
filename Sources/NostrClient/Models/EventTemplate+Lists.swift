import NostrCore

// MARK: - Lists and Sets (NIP-51)
extension EventTemplate {
    /// A NIP-51 list: its public items as tags, and its private items NIP-44-encrypted to
    /// `signer`'s own public key in the content.
    ///
    /// The content is empty when the list has no private items, and `signer` is then not used.
    /// Sign the template with the same signer, so only the author can read the private items back
    /// (see ``NostrList/init(event:decryptingWith:)``).
    /// https://github.com/nostr-protocol/nips/blob/master/51.md
    /// - Parameters:
    ///   - list: The list.
    ///   - signer: The author's signer, which encrypts the private items to itself.
    /// - Returns: The template for the list.
    /// - Throws: Anything resolving the signer's public key or encrypting throws.
    public static func list(
        _ list: NostrList,
        encryptingWith signer: some NostrSigning
    ) async throws -> EventTemplate {
        EventTemplate(
            kind: list.kind,
            tags: list.publicItems,
            content: try await ListItemCipher.seal(list.privateItems, with: signer)
        )
    }

    /// A NIP-51 set: its `d` identifier, presentation metadata, and public items as tags, and its
    /// private items NIP-44-encrypted to `signer`'s own public key in the content.
    ///
    /// Reserved metadata tags left in `publicItems` are dropped, so they are never emitted twice.
    /// The content is empty when the set has no private items, and `signer` is then not used.
    /// Sign the template with the same signer, so only the author can read the private items back
    /// (see ``NostrListSet/init(event:decryptingWith:)``).
    /// https://github.com/nostr-protocol/nips/blob/master/51.md
    /// - Parameters:
    ///   - set: The set.
    ///   - signer: The author's signer, which encrypts the private items to itself.
    /// - Returns: The template for the set.
    /// - Throws: Anything resolving the signer's public key or encrypting throws.
    public static func set(
        _ set: NostrListSet,
        encryptingWith signer: some NostrSigning
    ) async throws -> EventTemplate {
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
        tags.append(contentsOf: set.publicItems.filter { !NostrListSet.reservedTagNames.contains($0.name) })

        return EventTemplate(
            kind: set.kind,
            tags: tags,
            content: try await ListItemCipher.seal(set.privateItems, with: signer)
        )
    }
}
