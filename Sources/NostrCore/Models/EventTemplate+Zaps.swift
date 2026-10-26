import Foundation

// MARK: - Zaps (NIP-57)
extension EventTemplate {
    /// A zap request (kind 9734).
    ///
    /// A zap request is **not** published to relays — it is sent to the recipient's LNURL-pay
    /// callback (see ``LNURLPayResponse/invoiceRequestURL(amountMillisats:zapRequest:lnurl:)``),
    /// which returns a Lightning invoice and later publishes the matching kind-9735 zap receipt.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    /// - Parameters:
    ///   - recipient: The public key being zapped (the `p` tag).
    ///   - relays: Relays the recipient's wallet should publish the zap receipt to (the `relays`
    ///     tag, in canonical form); must contain at least one relay.
    ///   - amountMillisats: The amount in millisatoshis (the `amount` tag). Recommended.
    ///   - lnurl: The recipient's lnurl-pay URL, bech32-encoded with the `lnurl` prefix. Recommended.
    ///   - eventID: The id of the event being zapped, when zapping an event rather than a person
    ///     (the `e` tag).
    ///   - eventCoordinate: An event coordinate when zapping an addressable event (the `a` tag).
    ///   - comment: An optional message sent with the payment (the event content).
    /// - Returns: The template for the zap request.
    /// - Throws: ``NostrError/invalidData`` if `relays` is empty.
    public static func zapRequest(
        to recipient: PublicKey,
        relays: [RelayURL],
        amountMillisats: Int64? = nil,
        lnurl: String? = nil,
        eventID: EventID? = nil,
        eventCoordinate: String? = nil,
        comment: String = ""
    ) throws -> EventTemplate {
        // NIP-57 requires at least one relay so the recipient's wallet knows where to publish the
        // kind-9735 zap receipt; an empty list would otherwise yield a useless ["relays"] tag.
        guard !relays.isEmpty else {
            throw NostrError.invalidData
        }

        var tags: [Tag] = [
            Tag(name: "relays", values: relays.map(\.description)),
            .publicKey(recipient),
        ]
        if let amountMillisats {
            tags.append(Tag(name: "amount", values: [String(amountMillisats)]))
        }
        if let lnurl {
            tags.append(Tag(name: "lnurl", values: [lnurl]))
        }
        if let eventID {
            tags.append(.event(eventID))
        }
        if let eventCoordinate {
            tags.append(Tag(name: "a", values: [eventCoordinate]))
        }

        return EventTemplate(kind: .zapRequest, tags: tags, content: comment)
    }
}
