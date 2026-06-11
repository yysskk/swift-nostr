import Foundation
import NostrClient

// MARK: - Key Generation

// Generate a new random keypair
let keyPair = try! KeyPair()
print("=== Key Generation ===")
print("Private Key (hex): \(keyPair.privateKeyHex)")
print("Public Key (hex): \(keyPair.publicKeyHex)")
print("nsec: \(keyPair.nsec)")
print("npub: \(keyPair.npub)")
print()

// Import from existing private key
let existingPrivateKey = "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
let importedKeyPair = try! KeyPair(privateKeyHex: existingPrivateKey)
print("Imported keypair pubkey: \(importedKeyPair.publicKeyHex)")
print()

// MARK: - Event Creation & Signing

print("=== Event Creation ===")
let signer = EventSigner(keyPair: keyPair)

// Create a text note (kind 1)
let textNote = try! signer.signTextNote(content: "Hello, Nostr! 🤙")
print("Text Note:")
print("  ID: \(textNote.id)")
print("  Kind: \(textNote.kind)")
print("  Content: \(textNote.content)")
print("  Signature: \(textNote.sig.prefix(32))...")
print()

// Create a text note with tags
let taggedNote = try! signer.signTextNote(
    content: "Check out #nostr and #bitcoin!",
    tags: [
        ["t", "nostr"],
        ["t", "bitcoin"]
    ]
)
print("Tagged Note:")
print("  Content: \(taggedNote.content)")
print("  Tags: \(taggedNote.tags)")
print()

// MARK: - Event Verification

print("=== Event Verification ===")
let isValid = try! textNote.verify()
print("Signature valid: \(isValid)")
print()

// MARK: - User Metadata

print("=== User Metadata ===")
let metadata = UserMetadata(
    name: "Alice",
    about: "Nostr enthusiast",
    picture: "https://example.com/alice.png",
    nip05: "alice@example.com",
    lud16: "alice@getalby.com"
)
let metadataEvent = try! signer.signMetadata(metadata)
print("Metadata Event ID: \(metadataEvent.id)")
print("Kind: \(metadataEvent.kind) (setMetadata)")
print()

// MARK: - Reactions

print("=== Reactions ===")
let reaction = try! signer.signReaction(to: textNote, content: "+")
print("Reaction to \(textNote.id.prefix(16))...")
print("  Kind: \(reaction.kind)")
print("  Content: \(reaction.content)")
print("  Tags: \(reaction.tags)")
print()

// MARK: - Filters

print("=== Subscription Filters ===")

// Filter for a user's notes
let userNotesFilter = Filter.userNotes(pubkey: keyPair.publicKeyHex, limit: 20)
print("User notes filter:")
print("  Authors: \(userNotesFilter.authors?.first?.prefix(16) ?? "")...")
print("  Kinds: \(userNotesFilter.kinds ?? [])")
print("  Limit: \(userNotesFilter.limit ?? 0)")
print()

// Filter for global feed
let globalFilter = Filter.globalFeed(limit: 100)
print("Global feed filter:")
print("  Kinds: \(globalFilter.kinds ?? [])")
print("  Limit: \(globalFilter.limit ?? 0)")
print()

// Filter for mentions
let mentionsFilter = Filter.mentions(pubkey: keyPair.publicKeyHex, limit: 50)
print("Mentions filter:")
print("  Pubkey refs: \(mentionsFilter.pubkeyReferences?.first?.prefix(16) ?? "")...")
print()

// Custom filter with time range
let now = Int64(Date().timeIntervalSince1970)
var timeRangeFilter = Filter(
    kinds: [1, 6, 7],
    since: now - 86400, // Last 24 hours
    until: now,
    limit: 100
)
print("Time range filter (last 24h):")
print("  Kinds: \(timeRangeFilter.kinds ?? [])")
print("  Since: \(Date(timeIntervalSince1970: TimeInterval(timeRangeFilter.since ?? 0)))")
print()

// MARK: - Bech32 Encoding

print("=== Bech32 Encoding (NIP-19) ===")
let npub = keyPair.npub
let nsec = keyPair.nsec
print("npub: \(npub)")
print("nsec: \(nsec)")

// Decode npub back to hex
let decodedPubKey = try! PublicKey(npub: npub)
print("Decoded pubkey hex: \(decodedPubKey.hex)")
print()

// MARK: - JSON Serialization

print("=== JSON Serialization ===")
let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted
let eventJson = try! encoder.encode(textNote)
print("Event JSON:")
print(String(data: eventJson, encoding: .utf8)!)
print()

// MARK: - Client Usage Example (Async)

print("=== Client Usage Example ===")
print("""
// Connect to relays and publish
Task {
    let client = NostrClient()

    // Add relays
    try await client.addRelays([
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ])

    // Connect to all relays
    try await client.connect()

    // Set your private key
    try await client.setNsec("nsec1...")

    // Publish a text note — returns the signed event plus the per-relay outcome
    let note = try await client.publishTextNote(content: "Hello from playground!")
    print("Published event: \\(note.id), accepted by \\(note.result.acceptedRelays.count) relay(s)")

    // Subscribe to global feed (async sequence)
    let feed = try await client.subscribeToGlobalFeed(limit: 10)
    for await event in feed.events {
        print("Received: \\(event.content)")
    }

    // Ending the loop closes the subscription; or close explicitly:
    await feed.close()

    // Disconnect
    await client.disconnect()
}
""")

print("\n=== Playground Complete ===")
