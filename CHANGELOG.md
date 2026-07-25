# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **NIP-98 HTTP Auth**: `HTTPAuth` builds and signs kind-27235 authorization events and encodes
  them as `Authorization: Nostr <base64>` header values, with a
  `URLRequest.setNostrAuthorization(signer:)` convenience that signs the request's URL, method,
  and body. Works with any `NostrSigning` signer, local or remote. On the server side,
  `HTTPAuth.validate(authorization:url:method:payload:tolerance:now:)` performs the full NIP-98
  check chain — scheme, decoding, kind, signature, timestamp window, URL, method, and body
  hash — returning the verified event, with each failure reported as a typed
  `HTTPAuth.ValidationError`.
- **NIP-29 Relay-based groups (core events)**: group event kind constants,
  `h`/`previous`/`code`/`role`/`group` tag constructors, join/leave request builders,
  group-scoped content events, and timeline-reference helpers under the new `Groups` namespace.
- **NIP-29 Relay-based groups (state)**: typed parsing of relay-generated group state —
  `Groups.Metadata`, `Groups.AdminList`, `Groups.MemberList`, `Groups.RoleList`, and
  `Groups.PinList` — plus membership derivation from moderation history and a
  `Filter.groupState` convenience.
- **NIP-29 Relay-based groups (moderation)**: typed `Groups.ModerationAction` builders for the
  eight moderation kinds (put-user, remove-user, edit-metadata, delete-event, create-group,
  delete-group, create-invite, update-pin-list) and `Groups.ModerationRequest` parsing for
  admin and audit views.
- **NIP-29 Relay-based groups (client)**: `GroupReference` (naddr share links with invite codes),
  `GroupState` snapshots, and `NostrClient` flows — `joinGroup`, `leaveGroup`,
  `publishGroupMessage`, `publishGroupModeration`, `fetchGroupMetadata`/`fetchGroupState` with
  relay-author validation, and `subscribeToGroupTimeline` — all scoped to the group's relay.
- **NIP-29 Relay-based groups (group list)**: the NIP-51 kind-10009 simple group list as a typed
  `SimpleGroupList`/`GroupListEntry` view over `NostrList` — including NIP-44 private entries —
  with `fetchSimpleGroupList` and `publishSimpleGroupList` on `NostrClient`.

### Changed

- **Single import**: `NostrClient`, `NostrWalletConnect`, and `NostrConnect` now re-export
  `NostrCore`; a separate `import NostrCore` is no longer required to use the primitives
  (`Event`, `KeyPair`, `Filter`, …) they surface.
- `RemoteSigner.awaitConnection()` now throws a distinct `RemoteSignerError.connectionInProgress`
  when another wait is already running on the session, instead of conflating that with
  `.notConnected`. The new case is additive but a source break for code that switches over
  `RemoteSignerError` exhaustively.
- **Breaking**: `Contact.relayUrl` is now `Contact.relayURL`, matching the `relayURL` spelling of the
  tag API it feeds (`Tag.pubkey(_:relayURL:petname:)`) and the Swift API Design Guidelines rule that
  acronyms are uniformly cased. The `relayUrl:` argument label on both `Contact` initializers is
  renamed to `relayURL:` as well. Because `Contact` is `Codable`, its JSON key changes from
  `relayUrl` to `relayURL`; clients that persist encoded contacts need to migrate stored data.

## [0.6.0] - 2026-07-05

A large protocol and tooling release: ten new NIPs, a new `NostrConnect` library for
remote signing, a spec-compliance fix to NIP-44 encryption, and expanded test coverage.

### Added

- **NIP-13 Proof of Work**: `ProofOfWork` with leading-zero-bit `difficulty(ofHexId:)`,
  commitment-aware `validate(event:minimumDifficulty:)`, and a cooperative, cancellable
  `mine(event:difficulty:)`, plus `EventSigner.sign(_:proofOfWork:)`.
- **NIP-21 `nostr:` URIs**: `NIP19Entity(nostrURI:)` and `nostrURI`, rejecting `nsec` in both directions.
- **NIP-23 Long-form content**: `LongFormContent` (kind 30023 articles and 30024 drafts) with
  lossless metadata round-tripping, `naddr` addressing, and client publish/fetch helpers.
- **NIP-27 Content references**: `NostrContentReference` to find `nostr:` mentions in content and
  map them to `p`/`q`/`a` tags, plus a `Tag.quote` constructor.
- **NIP-45 Event counts**: `ClientMessage.count`/`RelayMessage.count`, `EventCount`, and
  `count(...)` on `RelayConnection`, `RelayPool`, and `NostrClient`.
- **NIP-46 Nostr Connect (remote signing)**: a new **`NostrConnect`** library — the `RemoteSigner`
  actor over a relay transport, both the signer-initiated `bunker://` and client-initiated
  `nostrconnect://` flows, `auth_url` challenges, and typed commands (sign, get_public_key, ping,
  nip44/nip04 encrypt/decrypt, switch_relays, logout).
- **NIP-49 Private key encryption**: `EncryptedPrivateKey` (`ncryptsec`) using scrypt and
  XChaCha20-Poly1305, plus `KeyPair.encryptedPrivateKey(password:)` / `KeyPair(ncryptsec:password:)`.
- **NIP-50 Search**: a `search` field on `Filter` and a `Filter.search(...)` convenience.
- **NIP-51 Lists**: standard lists (mute, pin, bookmarks) and parameterized sets (follow, relay,
  bookmark, curation, interest, emoji, …) as `NostrList` / `NostrListSet`, with NIP-44-self-encrypted
  private items and client publish/fetch helpers.
- **NIP-56 Reporting**: `ReportType`, `EventSigner.signReport(...)`, and `NostrClient.publishReport(...)`.
- **`NostrSigning` protocol** unifying local `EventSigner` and remote `RemoteSigner`; `NostrClient`
  gains `setSigner(_ : any NostrSigning)` and a public `sign(_:)`, and answers NIP-42 auth with either.
- Status badges and a Swift Package Index manifest (`.spi.yml`); a `CHANGELOG.md` and `CODE_OF_CONDUCT.md`.

### Fixed

- **NIP-44 encryption is now spec-compliant and interoperable.** The keystream used the AEAD
  ChaCha20 (block counter 1) and a floating-point padding calculation, so payloads did not match
  other Nostr clients. Encryption now uses bare ChaCha20 at counter 0 with the spec's integer
  padding, validated against the official NIP-44 vectors. **Payloads produced by earlier releases
  will not decrypt** — but they never interoperated with other clients.
- **Relay hardening**: `URLSessionWebSocket.cancel(with:)` degrades to `.invalid` instead of
  crashing on an unmapped close code, and automatic NIP-42 authentication failures are now
  observable via `RelayConnection.lastAuthenticationError`.

### Changed

- `ClientMessage`, `RelayMessage`, and `NostrError` gain new cases. These are additive but a source
  break for code that switches over them exhaustively.

## [0.5.0] - 2026-06-15

- Split the package into `NostrCore`, `NostrClient`, and `NostrWalletConnect` libraries.

## [0.4.0] - 2026-06-13

- NIP-47 Nostr Wallet Connect and NIP-57 Lightning zap support.

## [0.3.0] - 2026-06-11

- NIP-17 private direct messages, NIP-59 gift wrap, and NIP-44 encryption.

## [0.2.0] - 2026-04-10

- Multi-relay `RelayPool`, NIP-65 outbox model, and NIP-42 authentication.

## [0.1.0] - 2026-01-31

- Initial release: NIP-01 events, filters, subscriptions, and single-relay support.

[Unreleased]: https://github.com/yysskk/swift-nostr/compare/0.6.0...HEAD
[0.6.0]: https://github.com/yysskk/swift-nostr/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/yysskk/swift-nostr/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/yysskk/swift-nostr/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/yysskk/swift-nostr/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/yysskk/swift-nostr/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/yysskk/swift-nostr/releases/tag/0.1.0
