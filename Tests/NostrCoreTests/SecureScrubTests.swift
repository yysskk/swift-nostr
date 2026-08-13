import Foundation
import Testing

@testable import NostrCore

/// Scrubbing narrows the window in which freed memory still holds a usable key. It cannot be made
/// airtight in Swift, so these pin what it does do — and, just as importantly, that the crypto
/// paths it was added to still produce the same bytes.
@Suite("Secure Scrub Tests")
struct SecureScrubTests {

    @Test("scrubbing zeroes every byte")
    func scrubZeroesBytes() {
        var data = Data([0x01, 0x02, 0xff, 0x7f])
        data.secureScrub()

        #expect(data == Data([0, 0, 0, 0]))
    }

    @Test("scrubbing keeps the buffer's length")
    func scrubKeepsLength() {
        var data = Data(repeating: 0xab, count: 32)
        data.secureScrub()

        #expect(data.count == 32)
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test("scrubbing an empty buffer is a no-op")
    func scrubEmptyIsSafe() {
        var data = Data()
        data.secureScrub()

        #expect(data.isEmpty)
    }

    /// `Data` slices carry their parent's indices, so a scrub has to work from the value's own
    /// bounds rather than assume it starts at zero.
    @Test("scrubbing a slice zeroes the slice, not the whole parent")
    func scrubHonoursSliceBounds() {
        let parent = Data([1, 2, 3, 4, 5, 6])
        var slice = parent[2..<4]
        slice.secureScrub()

        #expect(Array(slice) == [0, 0])
        // The parent is a separate value here, so it keeps its own bytes.
        #expect(Array(parent) == [1, 2, 3, 4, 5, 6])
    }

    // MARK: - The paths scrubbing was added to still work

    @Test("NIP-44 still round-trips after scrubbing its derived keys")
    func nip44RoundTripsAfterScrub() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let sealed = try SealedMessage.seal("hello there", for: bob.publicKeyHex, using: alice)
        #expect(try sealed.open(from: alice.publicKeyHex, using: bob) == "hello there")
    }

    @Test("NIP-49 still round-trips after scrubbing its derived key")
    func nip49RoundTripsAfterScrub() throws {
        let privateKey = Data(repeating: 0x11, count: 32)
        let encrypted = try EncryptedPrivateKey.encrypt(
            privateKey: privateKey, password: "hunter2", logN: 14)

        #expect(try encrypted.decrypt(password: "hunter2", maxLogN: 14) == privateKey)
    }

    @Test("a conversation key is the same across repeated derivations")
    func conversationKeyIsStable() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let first = try SealedMessage.conversationKeyHex(
            privateKeyHex: alice.privateKeyHex, publicKeyHex: bob.publicKeyHex)
        let second = try SealedMessage.conversationKeyHex(
            privateKeyHex: alice.privateKeyHex, publicKeyHex: bob.publicKeyHex)

        // Scrubbing the ECDH shared point must not disturb the key derived from it.
        #expect(first == second)
        #expect(first.count == 64)
    }
}
