import NostrCore

// MARK: - Direct messages (NIP-17)
extension EventTemplate {
    /// A private direct message (kind 14) to `recipientPublicKey`, the rumor a NIP-17 send
    /// gift-wraps. Never sign it: deliver it with
    /// ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)``.
    /// https://github.com/nostr-protocol/nips/blob/master/17.md
    /// - Parameters:
    ///   - content: The message text.
    ///   - recipientPublicKey: The recipient, named by the `p` tag.
    ///   - subject: The conversation subject (the `subject` tag).
    ///   - replyTo: The event replied to, as an `e` tag with the `reply` marker.
    /// - Returns: The template for the message.
    public static func directMessage(
        _ content: String,
        to recipientPublicKey: PublicKey,
        subject: String? = nil,
        replyTo: EventID? = nil
    ) -> EventTemplate {
        var tags: [Tag] = [.publicKey(recipientPublicKey)]
        if let subject {
            tags.append(.subject(subject))
        }
        if let replyTo {
            tags.append(.event(replyTo, marker: .reply))
        }
        return EventTemplate(kind: .privateDirectMessage, tags: tags, content: content)
    }

    /// A NIP-25 reaction (kind 7) to a direct message, referencing the message's rumor id, its
    /// author, and its kind (14). Like the message, it is gift-wrapped and never signed.
    /// https://github.com/nostr-protocol/nips/blob/master/25.md
    /// - Parameters:
    ///   - messageID: The rumor id of the message reacted to (the `e` tag).
    ///   - author: The message's author (the `p` tag).
    ///   - content: The reaction: `"+"` for a like, `"-"` for a dislike, or an emoji.
    /// - Returns: The template for the reaction.
    public static func directMessageReaction(
        to messageID: EventID,
        author: PublicKey,
        content: String = "+"
    ) -> EventTemplate {
        EventTemplate(
            kind: .reaction,
            tags: [.event(messageID), .publicKey(author), .kind(.privateDirectMessage)],
            content: content
        )
    }

    /// A NIP-17 file message (kind 15) to `recipientPublicKey`: the attachment's URL as the content,
    /// and its MIME type, key, nonce, hashes, and metadata as tags. Like a message, it is
    /// gift-wrapped and never signed. Optional tags are omitted when the attachment leaves them nil.
    /// https://github.com/nostr-protocol/nips/blob/master/17.md
    /// - Parameters:
    ///   - attachment: The uploaded encrypted file, typically built with
    ///     ``FileAttachment/init(url:mimeType:encryption:size:dimensions:blurhash:)``.
    ///   - recipientPublicKey: The recipient, named by the `p` tag.
    /// - Returns: The template for the file message.
    public static func fileMessage(_ attachment: FileAttachment, to recipientPublicKey: PublicKey) -> EventTemplate {
        var tags: [Tag] = [.publicKey(recipientPublicKey)]
        if let mimeType = attachment.mimeType {
            tags.append(Tag(name: "file-type", values: [mimeType]))
        }
        tags.append(Tag(name: "encryption-algorithm", values: ["aes-gcm"]))
        tags.append(Tag(name: "decryption-key", values: [attachment.decryptionKey.base64EncodedString()]))
        tags.append(Tag(name: "decryption-nonce", values: [attachment.decryptionNonce.base64EncodedString()]))
        if let encryptedSHA256 = attachment.encryptedSHA256 {
            tags.append(Tag(name: "x", values: [encryptedSHA256]))
        }
        if let originalSHA256 = attachment.originalSHA256 {
            tags.append(Tag(name: "ox", values: [originalSHA256]))
        }
        if let size = attachment.size {
            tags.append(Tag(name: "size", values: [String(size)]))
        }
        if let dimensions = attachment.dimensions {
            tags.append(Tag(name: "dim", values: [dimensions]))
        }
        if let blurhash = attachment.blurhash {
            tags.append(Tag(name: "blurhash", values: [blurhash]))
        }
        return EventTemplate(kind: .fileMessage, tags: tags, content: attachment.url.absoluteString)
    }
}
