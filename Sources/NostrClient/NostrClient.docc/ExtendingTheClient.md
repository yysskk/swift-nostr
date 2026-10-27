# Extending the Client

Add NIP helpers and whole namespaces of your own, from outside the module.

## Overview

The capability protocols are the extension points. A helper added to a protocol in an extension
works on the client's namespace, on any conformer, and on a test stub alike; a namespace of your own
composes the protocols it needs and hangs off `NostrClient` through an extension. Neither needs
anything beyond the public API.

## Primitives and conveniences

Each capability protocol — ``NostrEventPublishing``, ``NostrEventFetching``,
``NostrIdentityProviding``, and the rest — requires only its primitives: the minimal operations
everything else is built from, every parameter spelled out, since Swift does not allow default
argument values on protocol requirements. ``NostrEventPublishing`` requires just
``NostrEventPublishing/publish(_:to:strategy:)-(EventTemplate,Set<RelayURL>?,_)`` and its
signed-event counterpart; ``NostrEventFetching`` requires
``NostrEventFetching/fetch(filters:from:timeout:)-(_,Set<RelayURL>?,_)`` and
``NostrEventFetching/countEvents(matching:from:timeout:)-(_,Set<RelayURL>?,_)``.

The conveniences — NIP helpers such as
``NostrEventPublishing/publishTextNote(content:tags:strategy:)`` and short forms of the primitives
such as `publish(_:)` — live in public protocol extensions, carry the default arguments, and are
built only on the primitives. For a conformer this means:

- Implement the primitives, without default arguments; a default there would make calls ambiguous
  with the short forms.
- Every convenience comes for free, and new ones added in later releases never break the build.
- Change behavior in a primitive, not by redeclaring a convenience: extension methods are
  dispatched statically, so a call through `any NostrEventPublishing` would still reach the
  extension's version.

## Adding a helper

A helper the package lacks is an extension of the capability it needs, built on that capability's
primitives or its existing conveniences. This one publishes a NIP-38 user status:

```swift
extension NostrEventPublishing {
    /// Signs and publishes a NIP-38 general user status (kind 30315) to the whole pool.
    @discardableResult
    public func publishStatus(
        _ status: String,
        expiration: Timestamp? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        var template = EventTemplate(
            kind: Event.Kind(rawValue: 30315), tags: [.identifier("general")], content: status)
        if let expiration {
            template.tags.append(.expiration(expiration))
        }
        return try await publish(template, strategy: strategy)
    }
}

try await client.events.publishStatus("Reading NIP-38")
```

It is available on `client.events`, on any `any NostrEventPublishing` a feature holds, and on every
stub, with no change to any of them.

## Adding a namespace

A feature area of your own is a `Sendable` struct holding the capabilities it needs — not the
client — plus an accessor on `NostrClient`. This one covers NIP-57 zaps: it signs zap requests
through ``NostrIdentityProviding`` and fetches the receipts paying the signer through
``NostrEventFetching``:

```swift
public struct ZapsAPI: Sendable {
    let events: any NostrEventFetching
    let identity: any NostrIdentityProviding

    public init(events: any NostrEventFetching, identity: any NostrIdentityProviding) {
        self.events = events
        self.identity = identity
    }

    /// Signs a zap request to send to the recipient's LNURL-pay callback.
    public func signRequest(
        to recipient: PublicKey,
        amountMillisats: Int64,
        relays: [RelayURL],
        comment: String = ""
    ) async throws -> Event {
        try await identity.sign(
            .zapRequest(to: recipient, relays: relays, amountMillisats: amountMillisats, comment: comment))
    }

    /// Fetches the zap receipts naming the signer as recipient.
    public func received(limit: Int = 50, timeout: Duration? = nil) async throws -> [ZapReceipt] {
        guard let publicKey = await identity.publicKey else { throw NostrClient.Error.signerNotSet }
        let filter = Filter(kinds: [.zap], publicKeyReferences: [publicKey], limit: limit)
        return try await events.fetch(filters: [filter], timeout: timeout).compactMap(ZapReceipt.init(event:))
    }
}

extension NostrClient {
    /// NIP-57 zap requests and receipts.
    public nonisolated var zaps: ZapsAPI { ZapsAPI(events: events, identity: identity) }
}

let receipts = try await client.zaps.received()
```

``NostrClient/NostrClient`` is an actor, so the accessor is declared `nonisolated`, like the
client's own ``NostrClient/events`` and ``NostrClient/identity`` it reads: reading `client.zaps`
needs no `await`. A namespace can hold any combination of capabilities: a member typed
`any NostrEventPublishing & NostrEventFetching` takes both halves of ``NostrClient/events``.

Receipts fetched this way are unverified claims; check one with
``ZapReceipt/validate(lnurlProviderPublicKey:expectedAmountMillisats:requiringDescriptionHash:)``
before trusting its amount.

## Testing against a stub

Because the namespace holds capabilities rather than the client, a test hands it a stub that
implements only the primitives. Real namespaces mix in freely: `client.identity` signs and reports
its key without any relay.

```swift
actor CannedEvents: NostrEventFetching {
    let events: [Event]
    private(set) var requests: [[Filter]] = []

    init(_ events: [Event]) { self.events = events }

    func fetch(filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> [Event] {
        requests.append(filters)
        return events
    }

    func countEvents(matching filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> Int {
        events.count
    }
}

@Test func receivedZaps() async throws {
    let client = NostrClient()
    let signer = EventSigner(keyPair: KeyPair())
    await client.identity.setSigner(signer)
    let events = CannedEvents([receipt])  // a kind-9735 event paying signer.publicKey
    let zaps = ZapsAPI(events: events, identity: client.identity)

    let receipts = try await zaps.received()

    #expect(receipts.map(\.amountMillisats) == [21_000])
    #expect(await events.requests == [[Filter(kinds: [.zap], publicKeyReferences: [signer.publicKey], limit: 50)]])
}
```

A helper is tested the same way: `publishStatus` called on a stub ``NostrEventPublishing`` hands
the template it built to the stub's
``NostrEventPublishing/publish(_:to:strategy:)-(EventTemplate,Set<RelayURL>?,_)``.
