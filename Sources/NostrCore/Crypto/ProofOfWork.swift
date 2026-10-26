import Foundation

/// NIP-13 proof of work: leading-zero-bit difficulty over event ids, with mining and validation.
/// https://github.com/nostr-protocol/nips/blob/master/13.md
public enum ProofOfWork {
    /// The number of leading zero bits in an event id, in `0...256`.
    public static func difficulty(of id: EventID) -> Int {
        var count = 0
        for byte in id.data {
            count += byte.leadingZeroBitCount
            if byte != 0 { break }
        }
        return count
    }

    /// Whether `event` satisfies `minimumDifficulty`: its id must have at least that many leading
    /// zero bits AND its `nonce` tag must commit to a target of at least that difficulty (a bare
    /// lucky id with no/short commitment is rejected for `minimumDifficulty > 0`). Does not verify
    /// the id or signature — use ``Event/verify()`` for that.
    public static func validate(event: Event, minimumDifficulty: Int) -> Bool {
        guard minimumDifficulty > 0 else { return true }

        guard difficulty(of: event.id) >= minimumDifficulty else { return false }

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
    /// - Throws: `CancellationError` if the task is cancelled;
    ///   ``ProofOfWork/Error/invalidDifficulty(_:)`` if `difficulty` is outside `0...256`.
    public static func mine(event: UnsignedEvent, difficulty: Int) async throws -> UnsignedEvent {
        guard 0...256 ~= difficulty else {
            throw Error.invalidDifficulty(difficulty)
        }

        let strippedTags = event.tags.filter { $0.first != "nonce" }
        let target = String(difficulty)

        var nonce = 0
        var iterations = 0
        while true {
            let candidate = UnsignedEvent(
                publicKey: event.publicKey,
                createdAt: event.createdAt,
                kind: event.kind,
                rawTags: strippedTags + [["nonce", String(nonce), target]],
                content: event.content
            )
            // `Self.` disambiguates from the `difficulty` parameter that shadows the method here.
            if Self.difficulty(of: try candidate.computedID) >= difficulty {
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

extension ProofOfWork {
    /// Why ``ProofOfWork/mine(event:difficulty:)`` could not mine an event.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The target difficulty is outside `0...256` (payload: the requested difficulty).
        case invalidDifficulty(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidDifficulty(let difficulty):
                return "A proof-of-work difficulty must be 0 to 256 bits, got \(difficulty)"
            }
        }
    }
}
