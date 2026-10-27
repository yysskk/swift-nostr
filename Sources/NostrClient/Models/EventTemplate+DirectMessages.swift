import NostrCore

// MARK: - Direct messages (NIP-17)
extension EventTemplate {
    /// A private direct message (kind 14) to `recipientPublicKey`, the rumor a NIP-17 send
    /// gift-wraps. Never sign it: deliver it with
    /// ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)-(_,_,Timestamp?,_)``.
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

    /// A NIP-17 file message (kind 15) to `recipientPublicKey`: the URL of a file encrypted with
    /// ``EncryptedFile/encrypt(_:)`` as the content, and the MIME type, key, nonce, and hashes as
    /// tags. Like a message, it is gift-wrapped and never signed.
    /// https://github.com/nostr-protocol/nips/blob/master/17.md
    /// - Parameters:
    ///   - url: The URL of the uploaded encrypted file.
    ///   - mimeType: The file's MIME type before encryption (the `file-type` tag).
    ///   - encryption: The encryption result whose key, nonce, and hashes describe the file.
    ///   - size: The encrypted file's size in bytes (the `size` tag).
    ///   - dimensions: Pixel dimensions as "<width>x<height>" (the `dim` tag).
    ///   - blurhash: A blurhash placeholder (the `blurhash` tag).
    ///   - recipientPublicKey: The recipient, named by the `p` tag.
    /// - Returns: The template for the file message.
    public static func fileMessage(
        url: URL,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil,
        to recipientPublicKey: PublicKey
    ) -> EventTemplate {
        var tags: [Tag] = [
            .publicKey(recipientPublicKey),
            Tag(name: "file-type", values: [mimeType]),
            Tag(name: "encryption-algorithm", values: ["aes-gcm"]),
            Tag(name: "decryption-key", values: [encryption.key.base64EncodedString()]),
            Tag(name: "decryption-nonce", values: [encryption.nonce.base64EncodedString()]),
            Tag(name: "x", values: [encryption.encryptedSHA256]),
            Tag(name: "ox", values: [encryption.originalSHA256]),
        ]
        if let size {
            tags.append(Tag(name: "size", values: [String(size)]))
        }
        if let dimensions {
            tags.append(Tag(name: "dim", values: [dimensions]))
        }
        if let blurhash {
            tags.append(Tag(name: "blurhash", values: [blurhash]))
        }
        return EventTemplate(kind: .fileMessage, tags: tags, content: url.absoluteString)
    }
}
