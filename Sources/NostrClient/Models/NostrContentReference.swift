import Foundation
import NostrCore

/// A `nostr:` reference found inside event content (NIP-27): where it appears and what it points to.
///
/// Clients embed NIP-21 entities (`nostr:npub1…`, `nostr:note1…`, …) inline in the content of an
/// event; this type both locates those references and derives the tags the referencing event should
/// carry for them (`p` for profile/pubkey mentions, `q` for note/nevent quotes, `a` for `naddr`).
/// https://github.com/nostr-protocol/nips/blob/master/27.md
public struct NostrContentReference: Sendable, Hashable {
    /// The full matched text, e.g. `"nostr:npub1..."`.
    public let text: String

    /// The range of ``text`` within the scanned content.
    public let range: Range<String.Index>

    /// The decoded entity. Never `nsec` — private keys are not references.
    public let entity: NIP19Entity

    /// Creates a reference. Fails when `entity` is `nsec`, keeping the stored ``entity``
    /// non-`nsec` by construction so ``tag`` never has to emit a private key.
    private init?(text: String, range: Range<String.Index>, entity: NIP19Entity) {
        if case .nsec = entity { return nil }
        self.text = text
        self.range = range
        self.entity = entity
    }

    /// Finds all decodable `nostr:` references in `content`, in order of appearance.
    ///
    /// The scheme is matched case-insensitively at a word boundary (the character before it must be
    /// absent or non-alphanumeric, so `xnostr:` is not matched), followed by the maximal run of
    /// bech32 characters. Malformed or non-referenceable entities (including `nsec`) are skipped.
    public static func references(in content: String) -> [NostrContentReference] {
        let scheme = "nostr:"
        var references: [NostrContentReference] = []
        var searchStart = content.startIndex

        // Search case-insensitively on `content` itself so every index is valid on it.
        // Lowercasing a copy first is unsafe: some code points expand under case folding
        // (e.g. `İ` U+0130 → two scalars), which shifts the indices of everything after them.
        while let schemeRange = content.range(
            of: scheme, options: [.caseInsensitive], range: searchStart..<content.endIndex)
        {
            searchStart = schemeRange.upperBound

            // Require a word boundary before the scheme so `xnostr:` is not matched.
            if schemeRange.lowerBound > content.startIndex {
                let previous = content[content.index(before: schemeRange.lowerBound)]
                if previous.isLetter || previous.isNumber { continue }
            }

            // Take the maximal run of bech32 characters after the scheme.
            var tokenEnd = schemeRange.upperBound
            while tokenEnd < content.endIndex, content[tokenEnd].isBech32Character {
                tokenEnd = content.index(after: tokenEnd)
            }
            guard tokenEnd > schemeRange.upperBound else { continue }

            let matchRange = schemeRange.lowerBound..<tokenEnd
            let token = String(content[schemeRange.upperBound..<tokenEnd])
            guard let entity = try? NIP19Entity.decode(token),
                let reference = NostrContentReference(
                    text: String(content[matchRange]),
                    range: matchRange,
                    entity: entity
                )
            else { continue }
            references.append(reference)
        }

        return references
    }

    /// The tag this reference contributes to the referencing event per NIP-27/NIP-18:
    /// `p` for npub/nprofile mentions, `q` for note/nevent quotes, `a` for `naddr` —
    /// each carrying the entity's first relay hint when present.
    public var tag: Tag {
        switch entity {
        case .npub(let publicKey):
            return .pubkey(publicKey)
        case .nprofile(let profile):
            return .pubkey(profile.publicKey, relayURL: profile.relays.first)
        case .note(let id):
            return .quote(id)
        case .nevent(let event):
            return .quote(event.eventId, relayURL: event.relays.first, pubkey: event.author)
        case .naddr(let addr):
            return .address(
                kind: Event.Kind(rawValue: addr.kind),
                pubkey: addr.author,
                identifier: addr.identifier,
                relayURL: addr.relays.first
            )
        case .nsec:
            // Unreachable: the initializer rejects nsec, so a stored entity is never a private key.
            preconditionFailure("NostrContentReference never stores an nsec entity")
        }
    }

    /// The deduplicated tags for every `nostr:` reference in `content`, in first-seen order.
    public static func tags(for content: String) -> [Tag] {
        var tags: [Tag] = []
        var seen: Set<[String]> = []
        for reference in references(in: content) {
            let tag = reference.tag
            if seen.insert(tag.rawArray).inserted {
                tags.append(tag)
            }
        }
        return tags
    }
}

extension Character {
    /// Whether this character is part of the lowercase bech32 token that follows a `nostr:` scheme.
    ///
    /// Bech32 strings are `[a-z0-9]` (human-readable prefix, the `1` separator, and the data section
    /// drawn from `qpzry9x8gf2tvdw0s3jn54khce6mua7l`); matching the whole ASCII alphanumeric range is
    /// a safe superset since decoding rejects any stray characters.
    fileprivate var isBech32Character: Bool {
        isASCII && (isLowercase || isNumber)
    }
}
