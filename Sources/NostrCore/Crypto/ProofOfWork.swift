import Foundation

/// NIP-13 proof of work: leading-zero-bit difficulty over event ids, with mining and validation.
/// https://github.com/nostr-protocol/nips/blob/master/13.md
public enum ProofOfWork {
    /// The number of leading zero bits in a hex-encoded event id.
    ///
    /// Each leading `0` hex character contributes four zero bits; the first non-zero nibble
    /// contributes its own leading zeros (`1` → 3, `2`–`3` → 2, `4`–`7` → 1, `8`–`f` → 0) and then
    /// counting stops. Counting also stops at the first non-hex character, so a fully-zero id of
    /// length `n` returns `n * 4`.
    public static func difficulty(ofHexId id: String) -> Int {
        var count = 0
        for character in id {
            guard let nibble = character.hexDigitValue else { break }
            if nibble == 0 {
                count += 4
            } else {
                // `leadingZeroBitCount` counts across the full Int width, so subtract everything
                // above the low nibble to keep the four-bit view: e.g. 0b0001 → 3, 0b1000 → 0.
                count += nibble.leadingZeroBitCount - (Int.bitWidth - 4)
                break
            }
        }
        return count
    }

    /// Whether `event` satisfies `minimumDifficulty`: its id must have at least that many leading
    /// zero bits AND its `nonce` tag must commit to a target of at least that difficulty (a bare
    /// lucky id with no/short commitment is rejected for `minimumDifficulty > 0`). Does not verify
    /// the id or signature — use ``Event/verify()`` for that.
    public static func validate(event: Event, minimumDifficulty: Int) -> Bool {
        guard minimumDifficulty > 0 else { return true }

        guard difficulty(ofHexId: event.id) >= minimumDifficulty else { return false }

        // The committed target lives in the third element of the nonce tag; without it a merely
        // lucky id could masquerade as intentional work, so an absent or short commitment fails.
        guard let nonceTag = event.tags.first(where: { $0.first == "nonce" }),
            nonceTag.count >= 3,
            let committedTarget = Int(nonceTag[2]),
            committedTarget >= minimumDifficulty
        else {
            return false
        }

        return true
    }

    /// Mines `event` to `difficulty` leading zero bits by iterating a `["nonce","<n>","<difficulty>"]`
    /// tag and recomputing the id. The `createdAt` timestamp is held fixed, so mining is deterministic.
    ///
    /// Cooperative: cancellation is checked and the task yields periodically, so a long-running mine
    /// can be cancelled promptly.
    ///
    /// - Parameters:
    ///   - event: The unsigned event to mine. Any existing `nonce` tags are replaced.
    ///   - difficulty: The target number of leading zero bits, in `0...256`.
    /// - Returns: A copy of `event` carrying a single `nonce` tag whose id meets `difficulty`.
    /// - Throws: `CancellationError` if the task is cancelled; ``NostrError/invalidData`` if
    ///   `difficulty` is outside `0...256`.
    public static func mine(event: UnsignedEvent, difficulty: Int) async throws -> UnsignedEvent {
        guard 0...256 ~= difficulty else {
            throw NostrError.invalidData
        }

        let strippedTags = event.tags.filter { $0.first != "nonce" }
        let target = String(difficulty)

        var nonce = 0
        var iterations = 0
        while true {
            let candidate = UnsignedEvent(
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                rawTags: strippedTags + [["nonce", String(nonce), target]],
                content: event.content
            )
            let id = try candidate.computedId
            // `Self.` disambiguates from the `difficulty` parameter that shadows the method here.
            if Self.difficulty(ofHexId: id) >= difficulty {
                return candidate
            }

            nonce += 1
            iterations += 1
            if iterations % 1024 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }
}
