# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`PrivateKey` is a typed secret key**: 32 bytes validated as a secp256k1 scalar — non-zero and
  below the curve order — by `init(hex:)`, `init(data:)`, and `init(nsec:)`, which throw
  `KeyPair.Error`. `hex`, `data`, and `nsec` export it. It is not `Codable`, and its `description`,
  `debugDescription`, and mirror are redacted, so `print`, string interpolation, and `dump` never
  show the key. Equality compares every byte in constant time.
- **`PublicKey`, `EventID`, and `Signature` are typed hex values**: each holds exactly one
  spelling, canonical lowercase hex (64, 64, and 128 digits), which is also its `description` and
  its JSON encoding. `init(hex:)`, `init(data:)`, `PublicKey(npub:)`, and `EventID(note:)` reject
  anything else — uppercase, the wrong length, non-hex, or a bech32 string with another prefix —
  with `PublicKey.Error`, `EventID.Error`, or `Signature.Error`; the failable `init?(_:)` returns
  nil, and decoding fails with `DecodingError.dataCorrupted`. `PublicKey.npub` and `EventID.note`
  give the NIP-19 forms and no longer throw. `EventID` is `Comparable` in byte order, the order
  NIP-01 breaks `created_at` ties by.
- **`RelayURL` is a typed relay URL**: a `ws` or `wss` URL held in canonical form — lowercased
  scheme and host, root trailing slash and default port removed, path case and a non-root trailing
  slash kept — so every spelling of a relay is the same value, and equality and hashing follow it.
  `RelayURL(string:)` and `RelayURL(url:)` throw `RelayURL.Error` for an unparseable string,
  another scheme, an empty host, a fragment, or a user or password; the failable `init?(_:)`
  returns nil. `description` and the JSON encoding are the canonical string,
  `url` is the `URL` the WebSocket opens, and decoding an invalid string fails with
  `DecodingError.dataCorrupted`.
- **`Timestamp` is a typed Unix time**: whole seconds since the epoch, with `rawValue: Int64` kept
  exactly as on the wire and a bare JSON integer encoding (decoding a non-integer fails).
  `Timestamp(_ date:)` truncates toward zero and clamps to ±2^53 seconds, infinity and NaN included,
  and `date` clamps the same way, so neither conversion traps. `Timestamp.now` is the current time;
  the type is `Comparable` and its `description` is the decimal seconds.
  `advanced(by:)` and `duration(to:)` do `Duration` arithmetic without going through `Date`:
  advancing drops the sub-second part of the duration (truncating toward zero) and saturates at the
  bounds of `Int64` instead of trapping.
- **`EventCoordinate` is a typed event coordinate**: the `kind`, `publicKey`, and `identifier` that
  address a replaceable or addressable event. Its `description` and JSON encoding are NIP-01's
  `<kind>:<pubkey>:<identifier>`; the failable `init?(_:)` splits at the first two colons only, so an
  identifier may contain `:`, and returns nil for a missing part, a non-canonical kind, or a
  non-canonical public key, and decoding such a string fails with `DecodingError.dataCorrupted`.
  `Event.coordinate` gives an event's coordinate (nil unless its kind is replaceable or addressable),
  and `NAddr.coordinate` an `naddr`'s, without its relay hints.
- **One-shot fetches and counts take their default timeout from configuration**:
  `RelayPoolConfig.queryTimeout` is how long a fetch or count through `NostrClient` or `RelayPool`
  waits for relays (EOSE, or COUNT) when the call passes no timeout, and
  `RelayConnectionConfig.queryTimeout` does the same for
  `RelayConnection.countEvents(matching:timeout:)`. Both default to 10 seconds.
- **`EventTemplate` describes an event before it is signed**: its `kind`, `tags`, `content`, and
  `createdAt` — everything but the public key, id, and signature — as mutable properties, so a
  template can be adjusted before signing. Static factories build the NostrCore events:
  `textNote(_:tags:)`, `reply(to:content:relayURL:)` (a NIP-10 reply carrying the parent's thread
  root, marked, and its author), `reaction(to:content:)`, `repost(of:relayURL:)`, `deletion(of:reason:)`,
  `clientAuthentication(relayURL:challenge:)`,
  `zapRequest(to:relays:amountMillisats:lnurl:eventID:eventCoordinate:comment:)`, the NIP-29
  `groupJoinRequest(groupID:inviteCode:reason:)`, `groupLeaveRequest(groupID:reason:)`,
  `groupContent(groupID:kind:content:tags:previous:)`, and `groupModeration(_:groupID:previous:reason:)`,
  and the NIP-98 `httpAuthorization(url:method:payload:)`.
  `NostrSigning.sign(_:)` signs a template as the signer's public key, so it works with a local
  `EventSigner` and a remote `RemoteSigner` alike, and `EventSigner.sign(_:)` does the same
  synchronously. `UnsignedEvent(_:publicKey:)` builds the unsigned event from a template.
- **NostrClient's models build `EventTemplate`s**: `metadata(_:)`, `contactList(_:)`,
  `relayListMetadata(_:)`, `directMessageRelayList(_:)`, `report(_:type:reason:)` for a public key or
  an event, and `longFormContent(_:draft:)`. NIP-51 lists and sets come from
  `list(_:encryptingWith:)` and `set(_:encryptingWith:)`, which NIP-44-encrypt the private items to
  the given signer's own key, and are read back with `NostrList(event:decryptingWith:)` and
  `NostrListSet(event:decryptingWith:)`; both take any `NostrSigning`, so a remote signer can now
  build and read lists without a `NostrClient`. `EventTemplate.openTimestamps` reads and sets a
  template's NIP-03 `ots` tag, replacing any existing one.
- **`RelayListMetadata(read:write:)` is public**, building a NIP-65 list from read and write relay
  URLs (a URL in both is read+write).
- **`events.publish(_:to:strategy:)` signs and publishes an `EventTemplate`**: the template is
  signed by the configured signer, local or remote, then sent to the whole pool or — with `to:` — to
  chosen relays, with the same targeting rules as publishing a signed event (an empty set throws,
  relays not in the pool are skipped). It returns a `PublishedEvent`. `publish(_:strategy:)` is the
  whole-pool short form.
- **`SubscriptionSequence(id:expectedRelays:stream:onClose:)` is public**, so a stub
  `NostrSubscribing` conformer can return a subscription over its own `AsyncStream`; `onClose` runs on
  every `close()`.
- **NIP-17 rumors are built as `EventTemplate`s**: `directMessage(_:to:subject:replyTo:)` (kind 14),
  `directMessageReaction(to:author:content:)` (kind 7, NIP-25), and
  `fileMessage(url:mimeType:encryption:size:dimensions:blurhash:to:)` (kind 15) produce the same tags
  and content the `DirectMessageBuilder` and `client.messages` sends always have, now from one source.
- **`DirectMessagePayloadSequence(subscription:parser:)` is public**, so a stub `NostrMessaging`
  conformer can return a payload stream that opens its own subscription's gift wraps.
- **The capability protocols are the documented way to extend `NostrClient`**: a new "Extending the
  Client" article covers adding a NIP helper in an extension of a capability protocol, which then
  works on the client's namespace, on any conformer, and on stubs, and adding a namespace of your
  own as a `Sendable` struct composing the capabilities it needs, exposed by a `nonisolated`
  accessor in an `extension NostrClient` and tested against stubs that implement only the
  primitives. Both need only the existing public API, which a test importing `NostrClient` without
  `@testable` now exercises.
- **`RemoteSigner.send(_:params:)` calls any NIP-46 method**: it sends the method with its
  positional string parameters over the same path as the typed commands — `auth_url` challenges
  and timeouts included — and returns the response's `result` string. It throws
  `RemoteSignerError.signerError(message:)` for an error response and `responseDecodingFailed` when
  the response has no result, so a method this package does not model can be called without a
  typed wrapper.
- **`WalletConnection.send(_:)` sends any NIP-47 command**: a `WalletConnectRequest` is a value that
  encodes as the request's `params`, naming its `WalletConnectMethod` and the `Response` type its
  `result` decodes into. `send(_:)` sends any conforming request, a command this package does not
  define included, over the same path as the typed commands: it waits for one response, rejects a
  `result_type` naming another method, and throws `WalletConnectError` as they do. The typed
  commands are now implemented on top of it.

### Changed

- **`KeyPair` holds a `PrivateKey`** (breaking): `privateKey` is a `PrivateKey` instead of `Data`,
  and `KeyPair(privateKey:)` takes one and no longer throws. `KeyPair(privateKey: Data)`,
  `KeyPair(privateKeyHex:)`, `privateKeyHex`, and `nsec` are removed in favor of `PrivateKey(data:)`,
  `PrivateKey(hex:)`, `privateKey.hex`, and `privateKey.nsec`; `KeyPair(nsec:)` stays.
  `EventSigner(privateKeyHex:)` is `EventSigner(privateKey:)`,
  `KeyDerivation.deriveNostrKey(seed:account:)` returns a `PrivateKey`, and
  `WalletConnectURI.secret` is a `PrivateKey`, so
  `WalletConnectURI(walletPublicKey:relays:secret:lud16:)` throws only for an empty relay list.
- **`Event.verify()` throws for every failure** (breaking): it returns `Void` and throws the new
  `Event.VerificationError.invalidSignature` for a signature that does not verify, instead of
  returning `false`. `Event.isValid` is the same check as a `Bool`, for when the reason does not
  matter.
- **`RelayConnection.send(_:)` no longer connects** (breaking): like `publish(_:)`, it throws
  `RelayConnection.Error.notConnected` when the connection is not established instead of spending
  up to `connectionTimeout` on a reconnect; call `connect()` first. `subscribe(subscriptionID:filters:)`
  still connects on demand. `RelayConnection.unsubscribe(subscriptionID:)` no longer throws: it
  forgets the subscription and sends `CLOSE` only when the connection is established and holds it,
  so drop the `try` at call sites. `RelayConnectionTransport.send(_:)` still reconnects a relay
  that dropped before sending to it.
- **`RemoteSignerError.secretMismatch` is removed** (breaking): nothing threw it. A signer that
  answers `connect` with a secret other than the one sent fails with `connectionRejected(message:)`.
- **Bounds are spelled `maximum` and `minimum`** (breaking): the remaining `max` and `min` names
  now match `minimumReconnectDelay`, `maximumLogN`, and `minimumDifficulty`.
  `RelayConnectionConfig.maxReconnectAttempts` and `maxReconnectDelay` are
  `maximumReconnectAttempts` and `maximumReconnectDelay`, and
  `RelayPoolConfig.maxDeduplicationCacheSize` is `maximumDeduplicationCacheSize`, in their
  initializers too. `RelayInformation.Limitation`'s `maxMessageLength`, `maxSubscriptions`,
  `maxFilters`, `maxLimit`, `maxEventTags`, and `maxContentLength` are `maximumMessageLength`,
  `maximumSubscriptions`, `maximumFilters`, `maximumLimit`, `maximumEventTags`, and
  `maximumContentLength`; `maxSubidLength` is `maximumSubscriptionIDLength` and
  `minPowDifficulty` is `minimumProofOfWorkDifficulty`. `LNURLPayResponse.minSendable` and
  `maxSendable` are `minimumSendable` and `maximumSendable`, and
  `LNURLPayResponse.InvoiceError.amountOutOfRange(min:max:)` is
  `amountOutOfRange(minimum:maximum:)`. `Groups.previousReferences(from:excludingAuthor:maxCount:)`
  and its `using:` overload take `maximumCount:`. The NIP-11 and LUD-06 JSON keys are unchanged.
- **`Event.Kind.categorizedPeopleList` is removed** (breaking): it was a second name for kind 30000.
  Use `followSet`, the NIP-51 name for that kind.
- **`PublishedEvent` no longer forwards `Event` properties** (breaking): the dynamic member lookup
  is removed, so read them through `event` (`published.event.id`, `published.event.content`).
- **Tag names are a typed `Tag.Name`** (breaking): `Tag.name` and `Tag(name:values:)` use
  `Event.Tag.Name`, an open `RawRepresentable` string type that encodes as a bare string and is
  `ExpressibleByStringLiteral`, so `Tag(name: "x")` and `tags(named: "x")` still compile. Constants
  are named after the typed constructor that emits them (`.event` for "e", `.publicKey` for "p",
  `.hashtag` for "t", `.identifier` for "d", `.inviteCode` for "code", `.simpleGroup` for "group",
  and so on). `Event.tags(named:)`, `Event.firstTagValue(named:)`, `Filter.addTagQuery(_:values:)`,
  `Filter.tagQuery(_:)`, and `Groups.ValidationError.missingTag(name:kind:)` take a `Tag.Name`;
  the filter methods still ignore a leading `#`. Passing a `String` variable now needs
  `Tag.Name(rawValue:)`.
- **`Event.tags` and `UnsignedEvent.tags` are `[Tag]`** (breaking), like `EventTemplate.tags`.
  A tag keeps the exact string array it was built or decoded from, so the JSON encoding and the
  NIP-01 id are unchanged and any tag a relay sends still decodes and verifies. An empty array is
  a tag too (an empty `name`, no `values`): decoding one no longer fails, `Event.tags` and
  private list items keep it, and `Tag(rawArray:)` is no longer failable. `Tag.raw(_:)`,
  `Tag`'s array-literal conformance, `Event.structuredTags` (read `tags`), and
  `UnsignedEvent.init(publicKey:createdAt:kind:rawTags:content:)` (pass `tags:`) are removed.
- **APIs that throw a single error type use typed throws** (breaking): callers now get the
  concrete error type without casting, so `catch .invalidBase64` or `error == .publicKeyMismatch`
  works directly. `HTTPAuth.validate(authorization:url:method:payload:tolerance:now:)` and
  `HTTPAuth.event(fromAuthorizationHeader:)` are `throws(HTTPAuth.ValidationError)`; the
  `init(event:relayPublicKey:)` of `Groups.Metadata`, `AdminList`, `MemberList`, `RoleList`, and
  `PinList`, and `Groups.ModerationRequest.init(event:)` are `throws(Groups.ValidationError)`; and
  `InternetIdentifier.verify(_:)`, `verify(_:expectedPublicKey:)`, `lookupPublicKey(_:)`,
  `lookupRelays(_:)`, and `String.verifyAsInternetIdentifier()` /
  `verifyAsInternetIdentifier(expectedPublicKey:)` are `async throws(InternetIdentifier.VerificationError)`.
- **APIs that cannot fail no longer throw, and more APIs use typed throws** (breaking): `KeyPair()`,
  `UnsignedEvent.serializedForHashing()`, `computedID`, and `asRumor()`, `EventSigner.sign(_:)` for an
  `EventTemplate`, `ClientMessage.serialize()`, `EventTemplate.repost(of:relayURL:)`, and
  `EncryptedFile.encrypt(_:)` no longer throw, so callers drop `try`. `EventSigner.sign(_:)` for an
  `UnsignedEvent` is `throws(EventSigner.Error)` and `HTTPAuth.authorizationHeaderValue(for:)` is
  `throws(HTTPAuth.AuthorizationError)`. `KeyPair(mnemonicPhrase:passphrase:account:)` and
  `KeyPair.generate(wordCount:passphrase:)` are `throws(KeyPair.Error)`, wrapping a bad phrase or word
  count in the new `KeyPair.Error.invalidMnemonic(Mnemonic.Error)`. `EncryptedPrivateKey.encrypt`,
  `decrypt(password:maximumLogN:)`, `KeyPair.encryptedPrivateKey(password:logN:keySecurity:maximumLogN:)`,
  and `KeyPair(ncryptsec:password:maximumLogN:)` are `throws(EncryptedPrivateKey.Error)`, which gains
  `invalidPrivateKeyLength(Int)`, `keyDerivationFailed`, and `invalidPrivateKey` (for a decrypted key
  that is not a valid secp256k1 scalar). `serializedForHashing()` writes the NIP-01 serialization
  itself instead of through `JSONSerialization`, with the same bytes on every platform.
- **Bech32, key, mnemonic, and NIP-49 failures have their own error types** (breaking): each
  domain throws a nested `Error` with typed throws, so callers can branch on why parsing failed.
  `Bech32.encode/decode/decodeToWords` throw `Bech32.Error` (`invalidHumanReadablePart`, `mixedCase`,
  `missingSeparator`, `invalidLength`, `invalidCharacter`, `invalidChecksum`, `invalidPadding`) instead
  of `NostrError.invalidBech32`. `PublicKey`, `EventID`, `Signature`, and `KeyPair` initializers throw
  `PublicKey.Error` / `EventID.Error` / `Signature.Error` / `KeyPair.Error` — `invalidHex`,
  `invalidLength(Int)`, and for npub/note/nsec `invalidBech32(Bech32.Error)` or
  `unexpectedPrefix(String)` — instead of `invalidPublicKey`, `invalidEventID`, `invalidSignature`,
  `invalidHex`, `invalidBech32`, and `unknownPrefix`; `KeyPair.Error.invalidPrivateKey` (also thrown by
  `KeyDerivation`) replaces `NostrError.invalidPrivateKey`. `EventSigner(privateKeyHex:)`,
  `EventSigner(nsec:)`, `setPrivateKey(_:)`, and `setNsec(_:)` throw `KeyPair.Error`. `Mnemonic.Error`
  replaces `invalidMnemonic` (now `invalidWordCount(Int)` or `invalidEntropyLength(Int)`),
  `invalidMnemonicWord` (`unknownWord`), and `invalidMnemonicChecksum` (`invalidChecksum`).
  `EncryptedPrivateKey.Error` replaces `invalidNcryptsec` (`malformedPayload`), `unsupportedScryptCost`,
  and NIP-49's `decryptionFailed`; encrypting a key that is not 32 bytes throws
  `EncryptedPrivateKey.Error.invalidPrivateKeyLength(Int)`. `LNURL.decode(_:)` throws `LNURL.Error` (`invalidBech32`,
  `unexpectedPrefix`, `invalidURL`). `KeyPair.nsec` and `LNURL.encode(_:)` no longer throw.
  Secure random bytes come from `SystemRandomNumberGenerator` on every platform, so
  `NostrError.randomGenerationFailed` is gone with the other replaced cases.
- **NIP-44, event verification, relay message, and relay URL failures have their own error
  types** (breaking): `SealedMessage` seal and open, and `EventSigner.nip44Encrypt/nip44Decrypt`,
  throw `SealedMessage.Error` with typed throws — `invalidConversationKey` and
  `invalidPlaintextLength(Int)` (were `encryptionFailed` / NIP-44's `decryptionFailed`),
  `invalidPublicKey` (a peer key not on secp256k1), `malformedPayload` (was `invalidPayloadFormat`),
  `unsupportedVersion(UInt8)` (was `unsupportedEncryptionVersion`), `invalidMAC` (was
  `hmacVerificationFailed`), and `invalidPadding`. `Event.verify()` is
  `throws(Event.VerificationError)` — `idMismatch` (was `invalidEventID`) or `missingSignature` (was
  `invalidSignature`).
  `RelayMessage.parse(_:)` is `throws(RelayMessage.Error)`, whose `malformed` replaces
  `invalidMessageFormat` and the `DecodingError` of an `EVENT` carrying a malformed event.
  `RelayURL(string:)` / `RelayURL(url:)` are `throws(RelayURL.Error)` — `malformed`,
  `unsupportedScheme(String)`, `missingHost`, `containsFragment`, `containsCredentials` — instead of
  `invalidRelayURL(String)`. `ProofOfWork.mine` and `sign(_:proofOfWork:)` throw
  `ProofOfWork.Error.invalidDifficulty(Int)`, `HTTPAuth.authorizationHeaderValue(for:)` and
  `URLRequest.setNostrAuthorization(signer:)` throw `HTTPAuth.AuthorizationError`
  (`invalidEventKind(Event.Kind)`, `missingURL`), and `EventTemplate.zapRequest` is
  `throws(EventTemplate.ZapRequestError)` (`missingRelays`), each instead of `invalidData`. The
  replaced `NostrError` cases are removed, along with the unused `signingFailed` and
  `subscriptionNotFound`.
- **NIP-19, gift wrap, direct-message, list, and group-reference failures have their own error
  types** (breaking): `NIP19Entity.decode(_:)`, `encoded`, `init(nostrURI:)`, `nostrURI`, and the
  `NProfile`, `NEvent`, and `NAddr` initializers and `encoded` are `throws(NIP19Entity.Error)` —
  `invalidBech32(Bech32.Error)` (was a bare `Bech32.Error`), `unknownPrefix(String)`,
  `unexpectedPrefix(String)` (another entity's prefix, was `unknownPrefix`), `malformedTLV` (was
  `invalidTLV`), `missingPublicKey` / `missingEventID` / `missingIdentifier` / `missingAuthor` /
  `missingKind`, `invalidLength(Int)`, `fieldTooLong(Int)` (was `invalidTLV`), `kindOutOfRange(Int)`,
  and `invalidHex` (each was `invalidNIP19Entity` or `invalidTLV`), and `missingNostrScheme` /
  `privateKeyInURI` (were `invalidNostrURI`); `LongFormContent.naddr(author:relays:)` and
  `NostrListSet.naddr(author:relays:)` throw it too. `GroupReference` is
  `throws(GroupReference.Error)` — `invalidCoordinate(NIP19Entity.Error)`, `unexpectedKind(Event.Kind)`,
  `missingRelay`, `unknownRelayPublicKey` — instead of `invalidNIP19Entity`. `GiftWrap.unwrap`
  throws `GiftWrap.Error`: `unexpectedKind(Event.Kind)` (was `invalidData`), `invalidSealSignature`
  and `authorMismatch` (were `verificationFailed`), and `invalidRumorID` (was `invalidEventID`).
  `DirectMessageParser` and `client.messages` `parse`, `parseReaction`, and `parseFile` throw
  `DirectMessagePayload.Error` — `unexpectedKind(Event.Kind)`, `invalidRecipient`,
  `missingReactionTarget`, `missingFileURL`, `invalidDecryptionKey`, `invalidDecryptionNonce` —
  instead of `invalidData`. `EncryptedFile.decrypt` is `throws(EncryptedFile.Error)`:
  `invalidKeyLength(Int)` and `invalidNonceLength(Int)` (a key that is not 32 bytes or a nonce that is
  not 12 is now rejected up front), `truncated`, and `authenticationFailed` (were `decryptionFailed`).
  `NostrListSet` throws `NostrListSet.Error` (`invalidKind(Event.Kind)`, `missingIdentifier`,
  `malformedPrivateItems`) with typed throws where it can, `NostrList` throws
  `NostrList.Error.malformedPrivateItems`, and `SimpleGroupList(list:)` is
  `throws(SimpleGroupList.Error)` (`invalidKind(Event.Kind)`), each instead of `invalidData` or
  `decryptionFailed`; private items that are not valid JSON now throw `malformedPrivateItems` rather
  than a `JSONSerialization` error. The replaced `NostrError` cases are removed, along with the
  unreachable `serializationFailed`.
- **Relay rejections and connection failures have their own error types** (breaking): a relay's
  OK `false` to `RelayConnection.publish(_:)` (after the NIP-42 auth retry) and CLOSED to
  `countEvents(matching:timeout:)` throw `RelayRejection`, whose `prefix: RelayResponsePrefix?` and
  `message` split the status string, so callers can `catch let rejection as RelayRejection` and
  branch on `rejection.prefix == .pow`; `RelayRejection(status:)` parses a raw status string. It
  replaces `NostrError.relayError("Relay rejected event <id>: …")` and the CLOSED `relayError`, and
  is the error in a pool publish's `PublishRelayStatus.failed`. Everything else `RelayConnection`
  detects throws `RelayConnection.Error`: `notConnected` (was `NostrError.notConnected`), `timedOut`
  (was `timeout`), `connectionFailed` (was `connectionFailed(String)`; the reason stays in
  `state`), `missingAuthenticationChallenge`, `invalidAuthenticationEventKind(Event.Kind)`, and
  `authenticationRejected(RelayRejection)` (each was `authenticationFailed(String)`), and
  `unsupportedFrame` (was `connectionFailed("Unsupported WebSocket frame")`).
  `RelayConnection.connect()` and `reconnect()` are `throws(RelayConnection.Error)`,
  `lastAuthenticationError` is an `(any Error)?` that usually holds a `RelayConnection.Error`, `RelayConnectionTransport` throws
  `RelayConnection.Error.notConnected` with typed throws, and `NostrIdentityAPI.authenticate(relayURL:)`
  throws `missingAuthenticationChallenge`. `NostrError.authenticationFailed` and `timeout` are
  removed.
- **Pool and client failures have their own error types, and `NostrError` is removed** (breaking):
  `RelayPool` throws `RelayPool.Error` — `emptyPool` (was `noRelaysInPool`), `noMatchingRelays([RelayURL])`,
  `cannotPublishAuthenticationEvent`, `quorumNotMet(acknowledged:required:)` (was
  `relayError("Publish quorum not met: …")`), `subscriptionSuperseded` and `subscriptionFailed` (were
  `relayError` strings), and `allConnectionsFailed` (was `connectionFailed("All relays failed to connect")`).
  `RelayPool.connectAll()`, `RelayPool.subscribe(subscriptionID:filters:to:handler:)`,
  `client.relays.connect()`, and `client.subscriptions.subscribe(filters:to:bufferingPolicy:)` are
  `throws(RelayPool.Error)`. Operations that need a signer throw `NostrClient.Error.signerNotSet`
  (was `NostrError.signerNotSet`), which capability extensions can throw too, and
  `client.routing.connectDirectMessageInboxRelays()` is `throws(NostrClient.Error)`. `NostrError` is
  removed: each domain now throws its own error type.
- **`Event.id`, `Event.pubkey`, and the event signature are typed** (breaking): `id` is an
  `EventID`, `pubkey` a `PublicKey`, and `sig: String` is now `signature: Signature?` — still the
  `sig` field on the wire. `Event.init` takes `signature:` instead of `sig:`. A `nil` signature is an
  unsigned NIP-59 rumor: it encodes without `sig`, a missing or empty `sig` decodes as `nil`, and
  `verify()` throws `missingSignature` for it. `UnsignedEvent.asRumor()` and gift-wrap unwrapping
  return rumors with a `nil` signature instead of an empty string.
- **Malformed events no longer decode** (breaking): an event whose `id`, `pubkey`, or `sig` is not
  canonical hex of the right length fails decoding rather than failing `verify()` later, so
  `RelayMessage.parse(_:)` throws for an `EVENT` frame carrying one and the relay connection drops it.
- **`UnsignedEvent.pubkey` is a `PublicKey`, and `computedId` is now `computedID: EventID`**
  (breaking). The `pubkey:` parameters of `UnsignedEvent.init`, `Groups.joinRequest`,
  `Groups.leaveRequest`, `Groups.contentEvent`, and `Groups.moderationEvent` take a `PublicKey`.
- **Filters take typed ids and public keys** (breaking): `Filter.ids` and `eventReferences` (`#e`)
  are `[EventID]?`, `authors` and `pubkeyReferences` (`#p`) are `[PublicKey]?`, and the factories
  `userNotes(pubkey:)`, `metadata(pubkeys:)`, `replies(to:)`, `mentions(pubkey:)`, `contactList`,
  `relayListMetadata`, and `directMessageRelayList` take them too. The wire format is unchanged —
  each value encodes as its hex string — and decoding a filter whose `ids`, `authors`, `#e`, or `#p`
  holds anything else fails.
- **Tag builders take typed values, and tag accessors return them** (breaking): `Tag.event`,
  `Tag.quote`, `Tag.pubkey` (both overloads), and `Tag.address` take an `EventID` and/or `PublicKey`
  and write its hex. `Event.referencedEventIds` is renamed `referencedEventIDs` and returns
  `[EventID]`; `referencedPubkeys` returns `[PublicKey]`. Tags are written by whoever authored the
  event, so a value that is not canonical hex is skipped rather than returned.
- **Event coordinates are `EventCoordinate`** (breaking): `Tag.address(_:relayURL:)` takes one in
  place of `kind:publicKey:identifier:`, as does `EventTemplate.zapRequest`'s `eventCoordinate:`;
  `Groups.PinnedItem.address`, `ZapReceipt.zappedEventCoordinate`, and
  `NostrListSet.coordinate(author:)` carry one instead of a `String`. An "a" value that is not a valid
  coordinate reads as nil, and a pin list skips it. The wire format is unchanged.
- **Signers deal in `PublicKey`** (breaking): `EventSigner.publicKey` and the `NostrSigning.publicKey`
  requirement are `PublicKey`, and `nip44Encrypt(_:to:)` / `nip44Decrypt(_:from:)` take one — on
  `EventSigner`, `NostrSigning`, and `RemoteSigner` alike — as do `SealedMessage.seal(_:for:using:)`
  and `open(from:using:)`. `EventSigner.signDeletion(eventIds:reason:)` is now
  `signDeletion(eventIDs:reason:)` taking `[EventID]`, and `signZapRequest` takes a `PublicKey`
  recipient and an `eventID: EventID?` (was `eventId: String?`). A `RemoteSigner` parses the
  signer's `get_public_key` reply and throws `RemoteSignerError.responseValidationFailed` for
  anything but a canonical hex key, from both `publicKey` and `userPublicKey()`.
- **`RelayMessage.ok` carries an `EventID`** (breaking): the case is now
  `ok(eventID:accepted:message:)`. An `OK` frame whose id is not canonical hex cannot answer any
  event this client sent, so `RelayMessage.parse(_:)` throws `invalidMessageFormat` for it, as it
  does for other malformed frames, and the relay connection drops it.
  `RelayConnection.authenticatedPubkeys` is a `Set<PublicKey>`.
- **Third-party documents read their public keys leniently** (breaking):
  `RelayInformation.pubkey` and `selfPubkey` (NIP-11) and `LNURLPayResponse.nostrPubkey` (NIP-57)
  are `PublicKey?`. A value that is not a canonical hex key decodes as `nil` instead of failing the
  whole document, so an LNURL endpoint advertising one no longer `supportsZaps`.
- **NIP-29 groups use typed keys and ids** (breaking): `relayPubkey:` on the state parsers,
  `Groups.ValidationError.unexpectedAuthor`, `Groups.Admin.pubkey`, `Groups.MemberList.members`,
  `Groups.membership(of:in:)`, `ModerationAction.putUser` / `removeUser`, and
  `previousReferences(from:excludingAuthor:…)` take `PublicKey`; `ModerationAction.deleteEvent(id:)`,
  `PinnedItem.event(id:)`, `previousReference(forEventID:)`, and
  `unknownPreviousReferences(of:knownEventIDs:)` take `EventID`. Parsing skips an admin, member, or
  pinned event whose value is not canonical hex, and a moderation event whose `p` or `e` target is
  malformed throws `missingTag` as if it were absent.
- **`ProofOfWork.difficulty(ofHexId:)` is now `difficulty(of:)`**, taking an `EventID` (breaking).
- **NostrClient takes and returns typed keys and event ids** (breaking): every `NostrClient` API
  that passed a public key or event id as a `String` now uses `PublicKey` or `EventID`, so there is
  no string left to validate at the boundary. `identity.publicKey` (and the `NostrIdentityProviding`
  requirement) is a `PublicKey?`; `identity.npub` is removed in favor of `publicKey?.npub`, and
  `identity.nip44Encrypt(_:to:)` / `nip44Decrypt(_:from:)` take a `PublicKey`. The `subscriptions`
  conveniences (`userTimeline`, `mentions`, `metadata(pubkeys:)`), `events.fetchEvent(id:)`,
  `fetchMetadata(pubkey:)`, `fetchLongFormContent(author:identifier:timeout:)`, and
  `publishReport(pubkey:…)`, the `routing` relay-list fetches, caches, and `subscribeOutbox(authors:)`,
  the `lists` fetches' `for:`, `groups.fetchMetadata` / `fetchState(authorPubkey:)` and
  `fetchSimpleGroupList(for:)`, `messages.send` / `sendFile` / `sendGiftWrapped(to:)` and
  `send(replyTo:)`, `DirectMessageBuilder`, `GiftWrap.wrap(recipientPubkey:)` and
  `UnwrappedMessage.senderPubkey`, `EventSigner.signContactList(pubkeys:)` and `signReport(pubkey:)`,
  `LongFormContent.naddr(author:)`, and `NostrListSet.naddr(author:)` / `coordinate(author:)` all take
  or return the typed values. `events.publishDeletion(eventIds:reason:strategy:)` is now
  `publishDeletion(eventIDs:reason:strategy:)` taking `[EventID]`.
- **NostrClient models hold typed keys and event ids** (breaking): `Contact.pubkey`,
  `GroupReference.relayPubkey`, `InternetIdentifier.VerificationResult.pubkey`, and the
  `senderPubkey` / `recipientPubkey` of `DirectMessage` and `DirectMessageFile` are `PublicKey`;
  `DirectMessage.rumorId` is now `rumorID: EventID` (also its `Identifiable` id) and `replyTo` is an
  `EventID?`. `DirectMessageReaction` has `rumorID`, `messageID: EventID` (was `messageId`), and a
  typed `senderPubkey` and `messageAuthorPubkey`; `DirectMessageFile.rumorId` is now `rumorID`.
  `Contact.init(npub:relayURL:petname:)` is removed in favor of `Contact(pubkey: PublicKey(npub:))`.
- **NIP-19 entities hold typed values** (breaking): `NIP19Entity.npub` carries a `PublicKey` and
  `.note` an `EventID` (`nsec` keeps its hex string), `NProfile.publicKey` and `NAddr.author` are
  `PublicKey`, and `NEvent.eventId` / `author` are now `eventID: EventID` and `author: PublicKey?`,
  with `NEvent.init(eventID:relays:author:kind:)`. Their initializers no longer throw `invalidHex`;
  decoding a key or id payload that is not 32 bytes throws `NIP19Entity.Error.invalidLength`.
- **NostrClient reads public keys and event ids from third-party data leniently** (breaking):
  `Contact.fromTag(_:)` returns nil, and `Event.contacts` skips the tag, for a `p` value that is not
  canonical hex. NIP-05 resolution treats a `nostr.json` key that is not canonical hex as absent, so
  `InternetIdentifier.verify` and `lookupPubkey` (which now returns a `PublicKey`) throw
  `pubkeyNotFound`, and `verify(_:expectedPubkey:)` compares typed keys rather than case-folded
  strings. `ZapReceipt.recipientPubkey`, `senderPubkey`, and `zappedEventId` (now `zappedEventID`)
  are typed and nil for a malformed tag, so `validate(lnurlProviderPubkey:…)` — which takes a
  `PublicKey` — reports a malformed `p` as `missingRecipient`. A received direct message whose `p`
  tag is malformed, or a reaction whose `e` or `p` tag is, fails to parse with a
  `DirectMessagePayload.Error`; a reply
  marker with a malformed id leaves `replyTo` nil.
- **NostrConnect and NostrWalletConnect take and return typed keys** (breaking):
  `RemoteSigner.clientPublicKey` is a `PublicKey` and `remoteSignerPubkey` a `PublicKey?`;
  `userPublicKey()` and `awaitConnection()` return a `PublicKey`, and `nip04Encrypt(_:to:)` /
  `nip04Decrypt(_:from:)` take one, as their NIP-44 counterparts already do.
  `BunkerURI.remoteSignerPubkey`, `NostrConnectURI.clientPubkey`, and `WalletConnectURI.walletPubkey`
  are `PublicKey`, and `BunkerURI(remoteSignerPubkey:relays:secret:)`,
  `NostrConnectURI(clientPubkey:relays:secret:permissions:name:url:image:)`, and
  `WalletConnectURI(walletPubkey:relays:secret:lud16:)` take one, so they no longer validate a key
  string. `WalletConnectURI.clientPublicKeyHex` is now `clientPublicKey: PublicKey`. The connection
  strings and the NIP-46 and NIP-47 request bodies are unchanged.
- **Connection URIs reject a non-canonical key** (breaking): parsing a `bunker://`,
  `nostrconnect://`, or `nostr+walletconnect://` string whose host is not canonical lowercase hex —
  uppercase hex included, which used to be folded to lowercase — throws
  `RemoteSignerError.invalidURI(reason:)` or `WalletConnectError.invalidURI(reason:)`.
- **`KeyPair.publicKey` is a `PublicKey`** (breaking): `KeyPair.publicKeyHex` and `KeyPair.npub`
  are removed in favor of `publicKey.hex` and `publicKey.npub`; the raw bytes are `publicKey.data`.
- **`EventSigner.npub` no longer throws** (breaking).
- **Relay and pool APIs take and return `RelayURL`** (breaking): there is no relay URL string left to
  validate past the boundary, and no `String`/`URL` overload pair. `RelayConnection(url:)` (both
  initializers) takes a `RelayURL` and `RelayConnection.url` is one; `RelayConnection(urlString:)` is
  removed in favor of `RelayConnection(url: RelayURL(string:))`. `RelayConnectionTransport(relayURLs:)`
  takes `[RelayURL]`, and `AuthenticationResponder` receives a `RelayURL`. On the pool,
  `RelayPool.addRelay(_:config:)`, `removeRelay(_:)`, `relay(for:)`, and `client.relays.add(_:config:)`,
  `remove(_:)`, and `relay(for:)` each take one `RelayURL`, and `addRelays(_:)`, `relays.add(_:)`, and
  `relays.connect(to:)` take any sequence of them; none of the membership calls throws any more.
- **Relay targets are a `Set<RelayURL>?`** (breaking): the `to:` parameter of `RelayPool.publish`,
  `count`, and `subscribe`, of `client.events.publish`, `fetch`, and `count`, and of
  `client.subscriptions.subscribe` and `events` (and their capability-protocol requirements) was
  `[String]?`. Nil still broadcasts to the whole pool, an empty set still throws, and targets not in
  the pool are still skipped; an invalid target can no longer reach these calls, so they no longer
  throw `invalidRelayURL`. `RelayPool.Error.noMatchingRelays` carries `[RelayURL]`, sorted by canonical
  string.
- **Relay results are keyed by `RelayURL`** (breaking): `PublishResult.statuses` is
  `[RelayURL: PublishRelayStatus]`, `acceptedRelays` / `failedRelays` / `pendingRelays` are
  `Set<RelayURL>`, and `status(for:)` takes a `RelayURL` (it took a string and returned nil for an
  invalid one). `RelayPool.countEvents(matching:from:timeout:)` returns `[RelayURL: EventCount]`;
  `SubscriptionSequence.expectedRelays` and the direct-message sequences' are `Set<RelayURL>`; every
  `SubscriptionEvent` case and its `relayURL` carry a `RelayURL`; and
  `routing.connectDirectMessageInboxRelays()` returns `Set<RelayURL>`.
- **NIP-42 authentication takes a `RelayURL`** (breaking): `identity.authenticate(relayURL:)`,
  `EventSigner.signClientAuthentication(relayURL:challenge:)`, and `Tag.relay(_:)`. The `relay` tag is
  the canonical URL, which is the URL the connection opens.
- **NIP-11 fetches take a `RelayURL`** (breaking): `RelayInformation.fetch(from:urlSession:)` takes one,
  `fetch(fromRelayURLString:urlSession:)` is removed, `informationURL(from:)` takes a `RelayURL` and
  no longer returns an optional, and `RelayInformation.FetchError.invalidRelayURL` is removed.
- **Relay hints are `RelayURL?`** (breaking): the `relayURL:` hint of `Tag.event`, `Tag.quote`,
  `Tag.pubkey(_:relayURL:petname:)`, and `Tag.address`, of `EventSigner.signRepost(of:relayURL:)`, and
  of `events.publishReply` and `publishRepost` is written in canonical form. `Contact.relayURL` is a
  `RelayURL?`, and `Contact.fromTag(_:)` reads a hint that is not a valid relay URL as nil rather than
  keeping the string. Hints read from other authors' events are parsed the same way: a reply to an
  event in NIP-10's positional form carries over its root's relay hint only when it is valid, and a
  `nostr:` `nprofile` / `nevent` / `naddr` reference's tag carries its first valid relay hint.
- **Relay lists hold `RelayURL`s** (breaking): `RelayListEntry.url`, `RelayListMetadata.readRelays` and
  `writeRelays`, and `DirectMessageRelayList.relays` are typed, as are
  `DirectMessageRelayList(relays:)`, `EventSigner.signRelayListMetadata(read:write:)` and
  `signDirectMessageRelayList(relays:)`, and `routing.publishRelayList(read:write:strategy:)` and
  `publishDirectMessageRelayList(relays:strategy:)` (with their `NostrRelayRouting` requirements). A
  NIP-65 `r` tag or NIP-17 `relay` tag whose URL is not a valid relay URL is skipped when parsing, so
  routing only ever sees usable relays; lists de-duplicate by relay and are written in canonical form
  instead of keeping the first spelling verbatim.
- **NIP-19 relay hints are `[RelayURL]`** (breaking): `NProfile.relays`, `NEvent.relays`, and
  `NAddr.relays`, their initializers, and `LongFormContent.naddr(author:relays:)` and
  `NostrListSet.naddr(author:relays:)`. Decoding skips a TLV relay record that is not a valid relay URL
  rather than keeping the raw string, and encoding writes each hint in canonical form; the 255-byte
  limit applies to that form.
- **NIP-29 groups name their relay with a `RelayURL`** (breaking): `GroupReference.relayURL`,
  `GroupReference(relayURL:id:relayPubkey:inviteCode:)`, `GroupListEntry.relayURL` and its initializer,
  `SimpleGroupList.relayURLs`, and `Tag.simpleGroup(id:relayURL:name:)`. `GroupReference(naddr:)` takes
  the coordinate's first valid relay hint, so the group flows no longer throw `invalidRelayURL`. In a
  kind-10009 list, a `group` tag or single-value `r` tag whose relay is not a valid relay URL is kept in
  the additional tags rather than parsed.
- **NIP-05 relays are `[RelayURL]`** (breaking): `InternetIdentifier.VerificationResult.relays` and
  `InternetIdentifier.lookupRelays(_:)`. A `nostr.json` relay entry that is not a valid relay URL is
  skipped.
- **`EventSigner.signZapRequest` takes `relays: [RelayURL]`** (breaking), written to the `relays` tag
  in canonical form.
- **Connection URIs hold `RelayURL`s** (breaking): `BunkerURI.relays`, `NostrConnectURI.relays`, and
  `WalletConnectURI.relays` are `[RelayURL]`, their initializers and `NostrConnectURI.invitation` take
  one, and `RemoteSigner.switchRelays()` returns `[RelayURL]?`. Parsing a `bunker://`,
  `nostrconnect://`, or `nostr+walletconnect://` string whose `relay` parameter is not a valid relay URL
  — a fragment, a user or password, or an empty host, besides a non-WebSocket scheme — throws
  `RemoteSignerError.invalidURI(reason:)` or `WalletConnectError.invalidURI(reason:)`, and a
  `switch_relays` reply with such an entry throws `responseDecodingFailed`. `stringValue` writes each
  relay in canonical form.
- **Event and filter times are `Timestamp`** (breaking): `Event.createdAt`,
  `UnsignedEvent.createdAt`, `Filter.since`, and `Filter.until` were `Int64`, as were the matching
  parameters of `Event.init`, `UnsignedEvent.init` (default `.now`), `Filter.init`, and
  `Filter.groupTimeline`. The wire format and event ids are unchanged.
- **NIP-29 and NIP-98 builders take a `Timestamp`** (breaking): the `createdAt:` parameters of
  `Groups.joinRequest`, `leaveRequest`, `contentEvent`, and `moderationEvent`, and of
  `HTTPAuth.authorizationEvent` and `authorizationHeaderValue(url:…)`, were `Date`; they default to
  `.now`. An infinite or out-of-range time no longer traps.
  `HTTPAuth.ValidationError.timestampOutOfTolerance(createdAt:)` carries the event's `Timestamp`.
- **NIP-40 expirations are `Timestamp`** (breaking): `Tag.expiration(_:)` takes one,
  `Event.expiration` returns one, and `Event.isExpired(asOf:)` compares against one (default `.now`).
  So does every `expiration:` parameter that was `Date?` — `client.messages.send`, `react`,
  `sendFile`, and `sendGiftWrapped`, the `NostrMessaging` requirements, the `DirectMessageBuilder`
  methods, and `GiftWrap.wrap`.
- **`subscriptionId` is spelled `subscriptionID`** (breaking): the acronym is now cased the same way
  as `groupID`, `eventID`, and `computedID` throughout. This renames the associated values of
  `ClientMessage.request`, `close`, and `count` and of `RelayMessage.event`, `endOfStoredEvents`,
  `closed`, and `count`, and the parameters of `RelayConnection.subscribe(subscriptionID:filters:)`,
  `unsubscribe(subscriptionID:)`, `RelayPool.unsubscribe(subscriptionID:)`, and
  `NostrSubscriptionsAPI.unsubscribe(subscriptionID:)`. The wire format is unchanged.
- **Conversions are initializers and properties** (breaking): following the Swift API Design
  Guidelines, which discourage `to`/`from` prefixes. `Mnemonic.fromEntropy(_:)` is
  `Mnemonic(entropy:)` and `Mnemonic.toSeed(passphrase:)` is `seed(passphrase:)`.
  `RelayListEntry.toTag()` and `Contact.toTag()` are a `tag: Tag` property, and their `fromTag(_:)`
  is `init?(tag: Tag)`; `OpenTimestamps.toTag()` is `tag: Tag`. `toTags() -> [[String]]` on
  `RelayListMetadata`, `DirectMessageRelayList`, and `LongFormContent` is `tags: [Tag]`, and
  `RelayListMetadata(tags:)` and `DirectMessageRelayList(tags:)` take `[Tag]`, so a list round-trips
  without passing through raw arrays; `LongFormContent.additionalTags` is `[Tag]` too. The NIP-29
  state models' `toTags` (`Groups.Metadata`, `AdminList`, `MemberList`, `RoleList`, `PinList`) is
  `tags`.
- **Wallet queries read as `fetch`** (breaking): `WalletConnection.getBalance()` is
  `fetchBalance()` and `getInfo()` is `fetchNodeInfo()`, matching `fetchInfo()` and the client's
  `fetchEvent`. `get_info` returns the wallet's Lightning node info, so it is named apart from
  `fetchInfo()`, which reads the kind-13194 info event. The `WalletConnectMethod` constants and the
  `GetBalanceResult`/`GetInfoResult` types keep their NIP-47 method names.
- **`Filter.getTagQuery(_:)` is removed** (breaking): use `tagQuery(_:)`, which it forwarded to.
- **Direct message times are `Timestamp`** (breaking): `createdAt` and `expiresAt` on
  `DirectMessage`, `DirectMessageReaction`, and `DirectMessageFile`, and their initializers, were
  `Date`. They carry the rumor's `created_at` and the gift wrap's `expiration` exactly as received.
- **Other protocol times are `Timestamp`** (breaking): `LongFormContent.publishedAt` (`published_at`
  is now kept exactly rather than clamped), the `since:` of `client.groups.timeline` and its
  `NostrGroupManaging` requirement, and `Bolt11Invoice.timestamp` were `Date`; NIP-47
  `WalletConnectTransaction.createdAt`, `expiresAt`, and `settledAt` and `ListTransactionsParams.from`
  and `until` were `Int64`. The NIP-47 JSON is unchanged.
- **Relay connection periods are `Duration`** (breaking): `RelayConnectionConfig.connectionTimeout`,
  `sendTimeout`, `publishAckTimeout`, `pingInterval`, `initialReconnectDelay`, and
  `maxReconnectDelay` were `TimeInterval`, and `RelayConnectionConfig.minimumReconnectDelay` is now
  `.milliseconds(100)`. The defaults are unchanged.
- **`RelayPoolConfig.deduplicationCacheTTL` is a `Duration`** (breaking); the default is still five
  minutes.
- **Session timeouts are `Duration`** (breaking): `RemoteSigner.Config.requestTimeout` and
  `authChallengeTimeout`, and `WalletConnection.Config.requestTimeout`, were `TimeInterval`. The
  defaults are unchanged.
- **`HTTPAuth.validate` takes a `Duration` tolerance and a `Timestamp` clock** (breaking):
  `tolerance:` was `TimeInterval` (default `.seconds(60)`) and `now:` was `Date` (default `.now`).
- **Invoice expiries are `Duration`** (breaking): `Bolt11Invoice.expirySeconds: Int64?` is now
  `expiry: Duration?`, and NIP-47 `MakeInvoiceParams.expiry` was `Int64?`. The NIP-47 `expiry`
  field still carries whole seconds; a sub-second part is truncated toward zero when encoding.
- **NIP-11 periods are `Duration`** (breaking): `RelayInformation.Limitation`'s
  `createdAtLowerLimit` and `createdAtUpperLimit` were `Int64?` documented as Unix times; NIP-11
  defines them as offsets from the relay's current time, which is what they now model.
  `FeeSchedule.period` and `Retention.time` were `Int?`; a retention `time` of `.zero` still means
  events are not stored, and `nil` means no time limit. The document still carries integer seconds,
  and a non-integer value still fails decoding.
- **Per-call fetch and count timeouts are `Duration?`** (breaking): the `timeout:` of every one-shot
  fetch and count on `client.events`, `client.routing`, `client.groups`, and `client.lists`, of
  `RelayPool.count`, of `RelayConnection.count`, and of the matching capability protocol
  requirements was `TimeInterval` defaulting to 10. It now defaults to `nil`, which uses the
  configured `queryTimeout`; `RelayPool.count` passes its resolved timeout to every connection, so
  the pool's setting governs pool calls.
- **`maxLogN` is spelled `maximumLogN`** (breaking): `EncryptedPrivateKey.decrypt(password:maxLogN:)`
  is `decrypt(password:maximumLogN:)` and `KeyPair(ncryptsec:password:maxLogN:)` is
  `KeyPair(ncryptsec:password:maximumLogN:)`, so reading and writing a NIP-49 key bound the scrypt
  cost with the same unabbreviated name `encrypt` already used.
- **Relay counts and NIP-45 counts are named apart** (breaking): `count` meant both the number of
  relays and a COUNT query. `NostrRelaysAPI.count` and `RelayPool.count` are `relayCount`, and
  `connectedCount()` on `NostrRelaysAPI`, `RelayPool`, and `NostrRelayManaging` is
  `connectedRelayCount()`. The NIP-45 queries `NostrEventsAPI.count(filters:to:timeout:)`,
  `RelayPool.count(filters:to:timeout:)`, and the `NostrEventFetching` requirement are
  `countEvents(matching:from:timeout:)`, and `RelayConnection.count(filters:timeout:)` is
  `countEvents(matching:timeout:)`.
- **Fetches read from relays** (breaking): `NostrEventsAPI.fetch(filters:to:timeout:)` and the
  `NostrEventFetching` requirement are `fetch(filters:from:timeout:)`, so a scoped fetch reads as
  fetching from those relays. `publish(_:to:)` and `subscribe(filters:to:)` keep `to`.
- **NostrCore spells public keys `publicKey`** (breaking): the same concept was spelled `pubkey`,
  `xxxPubkey`, and `publicKey`. Swift names now follow the API Design Guidelines, as `signature` and
  `createdAt` already did; the JSON keys (`pubkey`, `self`, `nostrPubkey`, `#p`) are unchanged.
  `Event.pubkey` and `UnsignedEvent.pubkey` (and their `pubkey:` initializer labels) are
  `publicKey`. `Tag.pubkey(_:relayURL:petname:)` and `Tag.pubkey(_:roles:)` are
  `Tag.publicKey(...)`, the `pubkey:` labels of `Tag.event`, `Tag.quote`, and `Tag.address` are
  `publicKey:`, and `Event.referencedPubkeys` is `referencedPublicKeys`. `Filter.pubkeyReferences` is
  `publicKeyReferences`, and the factories take `publicKey:`/`publicKeys:`
  (`userNotes(publicKey:limit:)`, `metadata(publicKeys:)`, `mentions(publicKey:limit:)`, and the
  `contactList`, `relayListMetadata`, and `directMessageRelayList` overloads).
  `RelayInformation.pubkey`/`selfPubkey` are `publicKey`/`selfPublicKey`, and
  `LNURLPayResponse.nostrPubkey` is `nostrPublicKey`. In NIP-29, the state parsers take
  `relayPublicKey:`, `Groups.Admin.pubkey` is `publicKey`, `Groups.ModerationAction.putUser(pubkey:roles:)`
  and `removeUser(pubkey:)` are `putUser(publicKey:roles:)` and `removeUser(publicKey:)`, and the
  `joinRequest`, `leaveRequest`, `contentEvent`, and `moderationEvent` builders take `publicKey:`.
  `EventSigner.signZapRequest(recipientPubkey:...)` is `signZapRequest(recipientPublicKey:...)`, and
  `RelayConnection.authenticatedPubkeys` is `authenticatedPublicKeys`. The `NostrSigning` and
  `EventSigner` NIP-44 methods and `SealedMessage` name their parameters `recipientPublicKey` and
  `senderPublicKey`; their argument labels are unchanged.
- **NostrClient spells public keys `publicKey`** (breaking): the rename NostrCore made now covers
  the client models and APIs, so `publicKey` names one concept everywhere; the JSON keys and tags
  are unchanged. `EventSigner.signContactList(pubkeys:)` and `signReport(pubkey:type:reason:)` are
  `signContactList(publicKeys:)` and `signReport(publicKey:type:reason:)`. `Contact.pubkey` and
  `Contact(pubkey:relayURL:petname:)` are `publicKey` (still `pubkey` in JSON). In NIP-05,
  `InternetIdentifier.VerificationResult.pubkey` (and its initializer label) is `publicKey`,
  `verify(_:expectedPubkey:)` is `verify(_:expectedPublicKey:)`, `lookupPubkey(_:)` is
  `lookupPublicKey(_:)`, `String.verifyAsInternetIdentifier(expectedPubkey:)` is
  `verifyAsInternetIdentifier(expectedPublicKey:)`, and `VerificationError.pubkeyNotFound` and
  `pubkeyMismatch` are `publicKeyNotFound` and `publicKeyMismatch`. `DirectMessage` and
  `DirectMessageFile` `senderPubkey`/`recipientPubkey`, `DirectMessageReaction.senderPubkey` and
  `messageAuthorPubkey`, and `GiftWrap.UnwrappedMessage.senderPubkey` are `senderPublicKey`,
  `recipientPublicKey`, and `messageAuthorPublicKey`; `GiftWrap.wrap(event:signer:recipientPubkey:expiration:)`
  and `DirectMessageBuilder.createReactionWithSelfCopy`'s `recipientPubkey:` take
  `recipientPublicKey:`. `ZapReceipt.recipientPubkey`/`senderPubkey` are
  `recipientPublicKey`/`senderPublicKey`, `validate(lnurlProviderPubkey:...)` is
  `validate(lnurlProviderPublicKey:...)`, and `ValidationError.payeePubkeyMismatch` is
  `payeePublicKeyMismatch`. `GroupReference.relayPubkey` (and its initializer label) is
  `relayPublicKey`, and `NostrGroupsAPI.fetchState` and `fetchMetadata` (and their
  `NostrGroupManaging` requirements) take `authorPublicKey:`. `NostrSubscriptionsAPI.userTimeline(pubkey:limit:)`, `mentions(pubkey:limit:)`,
  and `metadata(pubkeys:)` and `NostrEventsAPI.fetchMetadata(pubkey:timeout:)` and
  `publishReport(pubkey:type:reason:strategy:)` take `publicKey:`/`publicKeys:`, as do the matching
  `NostrEventPublishing`, `NostrEventFetching`, and `NostrSubscribing` requirements.
- **NostrConnect spells public keys `publicKey`** (breaking): `RemoteSigner.remoteSignerPubkey` is
  `remoteSignerPublicKey`, `BunkerURI.remoteSignerPubkey` and `BunkerURI(remoteSignerPubkey:relays:secret:)`
  are `remoteSignerPublicKey`, and `NostrConnectURI.clientPubkey` and its `clientPubkey:` initializer
  label are `clientPublicKey`. The NIP-04 and NIP-44 commands name their parameter
  `thirdPartyPublicKey`; their argument labels are unchanged.
- **NostrWalletConnect spells public keys `publicKey`, and Lightning node keys `nodePublicKey`**
  (breaking): `WalletConnectURI.walletPubkey` and its `walletPubkey:` initializer label are
  `walletPublicKey`. `PayKeysendParams.pubkey`, `MultiPayKeysendParams.Keysend.pubkey`, and
  `GetInfoResult.pubkey` (and their initializer labels) are `nodePublicKey`: each is a Lightning
  node's hex public key, not a Nostr `PublicKey`, so it stays a `String` and takes a name of its
  own. The NIP-47 JSON key is still `pubkey`.
- **Events are signed from `EventTemplate`s** (breaking): `EventSigner.signTextNote(content:tags:)`,
  `signReaction(to:content:)`, `signRepost(of:relayURL:)`, `signDeletion(eventIDs:reason:)`,
  `signClientAuthentication(relayURL:challenge:)`, and `signZapRequest(recipientPublicKey:...)` are
  removed. Sign the matching template instead — `signer.sign(.textNote("gm"))`,
  `.deletion(of:reason:)`, `.zapRequest(to:relays:...)`, and so on — which also works with a remote
  signer, so a `RemoteSigner` can now sign zap requests.
- **Proof of work mines a template with any signer** (breaking): `EventSigner.sign(_:proofOfWork:)`
  taking an `UnsignedEvent` is replaced by `NostrSigning.sign(_:proofOfWork:)` taking an
  `EventTemplate`. To mine an `UnsignedEvent` keyed in advance, use
  `ProofOfWork.mine(event:difficulty:)` and sign the result.
- **`identity.sign(_:)` signs an `EventTemplate`** (breaking): `NostrIdentityAPI.sign(_:)` and the
  `NostrIdentityProviding` requirement take a template and sign it as the configured signer's public
  key, instead of an `UnsignedEvent` the caller had to key with `identity.publicKey`.
- **`RelayConnection.authenticate(using:)` takes any `NostrSigning`**, so a remote signer can answer
  a relay's AUTH challenge on a direct connection too.
- **NostrClient's models are signed from `EventTemplate`s** (breaking):
  `EventSigner.signMetadata(_:)`, `signContactList(_:)`, `signContactList(publicKeys:)`,
  `signRelayListMetadata(_:)`, `signRelayListMetadata(read:write:)`, `signDirectMessageRelayList(_:)`,
  `signDirectMessageRelayList(relays:)`, `signReport(publicKey:type:reason:)`,
  `signReport(event:type:reason:)`, `signLongFormContent(_:draft:)`, `signList(_:)`, and `signSet(_:)`
  are removed. Sign the matching template instead — `signer.sign(.metadata(profile))`,
  `.contactList(publicKeys.map { Contact(publicKey: $0) })`,
  `.relayListMetadata(RelayListMetadata(read:write:))`,
  `.directMessageRelayList(DirectMessageRelayList(relays:))`, `.report(publicKey, type:)`, and so on;
  a list or set is `try await signer.sign(EventTemplate.list(list, encryptingWith: signer))`.
- **NIP-51 private items are decrypted by an initializer** (breaking): `EventSigner.openList(_:)` and
  `openSet(_:)` are replaced by `NostrList(event:decryptingWith:)` and
  `NostrListSet(event:decryptingWith:)`, which take any `NostrSigning`.
- **OpenTimestamps attach to a template** (breaking): `UnsignedEvent.withOpenTimestamps(_:)` and
  `EventSigner.sign(_:withOTS:)` are replaced by setting `EventTemplate.openTimestamps` before
  signing.
- **NIP-29 group and NIP-98 authorization events are built as `EventTemplate`s** (breaking):
  `Groups.joinRequest`, `leaveRequest`, `contentEvent`, and `moderationEvent` — both the `publicKey:`
  variants returning an `UnsignedEvent` and the `signer:` variants returning a signed `Event` — are
  removed, as are `HTTPAuth.authorizationEvent(url:method:payload:createdAt:signer:)` and
  `HTTPAuth.authorizationHeaderValue(url:method:payload:createdAt:signer:)`. Sign the matching
  template instead — `signer.sign(.groupJoinRequest(groupID: id))`,
  `.groupModeration(action, groupID: id)`, and so on, setting the template's `createdAt` for a custom
  time — and encode a signed `.httpAuthorization(url:method:payload:)` event with
  `HTTPAuth.authorizationHeaderValue(for:)`. `URLRequest.setNostrAuthorization(signer:)` is unchanged.

- **`NostrEventPublishing` and `NostrEventFetching` require only their primitives** (breaking):
  `NostrEventPublishing` requires `publish(_:to:strategy:)` for an `EventTemplate` and for a signed
  `Event`, and `NostrEventFetching` requires `fetch(filters:from:timeout:)` and
  `countEvents(matching:from:timeout:)`. `publishTextNote`, `publishReply`, `publishMetadata`,
  `publishReaction`, `publishRepost`, `publishDeletion`, both `publishReport` overloads,
  `publishLongFormContent`, `fetchEvent`, `fetchMetadata`, and both `fetchLongFormContent` overloads
  move to protocol extensions built on those primitives, with the same signatures and defaults, as do
  the short forms `publish(_:strategy:)`, `fetch(filters:timeout:)`, and
  `countEvents(matching:timeout:)`. A conformer implements the four primitives and inherits the rest,
  and a call through `any NostrEventPublishing` takes the same defaults as one through
  `client.events`. The targeted short forms take a non-optional `Set<RelayURL>`, so
  `publish(event, to: nil)` without a `strategy:` and `fetch(filters:from: nil)` without a `timeout:`
  no longer compile: omit `to:` / `from:` to reach the whole pool.

- **`NostrSubscribing`, `NostrRelayManaging`, and `NostrIdentityProviding` require only their
  primitives** (breaking): `NostrSubscribing` requires `subscribe(filters:to:bufferingPolicy:)`,
  `unsubscribe(subscriptionID:)`, and `unsubscribeAll()`; `NostrRelayManaging` requires
  `add(_:config:)`, `remove(_:)`, `connect()`, `disconnect()`, `connections`,
  `connectedRelayCount()`, `relay(for:)`, and `clearDeduplicationCache()`; `NostrIdentityProviding`
  keeps every requirement but `setPrivateKey(_:)` and `setNsec(_:)`. Both `events(filters:…)`
  shapes, `userTimeline`, `globalFeed`, `mentions`, `metadata(publicKeys:)`, `add(_:)` for one relay
  and for a sequence, `connect(to:)`, `relayCount`, `setPrivateKey(_:)`, and `setNsec(_:)` move to
  protocol extensions built on those primitives, with the same filters, defaults, and errors, as do
  the short forms `subscribe(filters:bufferingPolicy:)` and `subscribe(filters:to:bufferingPolicy:)`
  for a non-optional `Set<RelayURL>`, so `subscribe(filters:to: nil)` without a `bufferingPolicy:`
  and `events(filters:to: nil)` no longer compile: omit `to:` to subscribe on the whole pool.

- **`NostrMessaging` requires only its primitives, and `sendGiftWrapped` takes an `EventTemplate`**
  (breaking): the requirements are `sendGiftWrapped(_:to:expiration:strategy:)`,
  `parsePayload(_:)`, `payloads(limit:)`, and `giftWraps(limit:)`. `sendGiftWrapped` now authors the
  rumor from a template under the configured signer's public key, so the `UnsignedEvent` overload and
  its `invalidPublicKey` check for a rumor authored under another key are gone. `send`, `react`, and
  `sendFile` move to a protocol extension that gift-wraps the matching `EventTemplate` factory
  through `sendGiftWrapped`, with the same tags, routing, defaults, and errors; `parse`,
  `parseReaction`, and `parseFile` unwrap the matching case of `parsePayload(_:)`, throwing
  `DirectMessagePayload.Error.unexpectedKind` for any other payload; and `subscribe(limit:)`
  delivers the messages of `payloads(limit:)`. The extension also adds the short forms `sendGiftWrapped(_:to:strategy:)`,
  `sendGiftWrapped(_:to:expiration:strategy:)` for a non-optional `Timestamp`, `payloads()`, and
  `giftWraps()`, so an optional `expiration:` without a `strategy:` no longer compiles: pass
  `strategy: nil` as well, or omit a nil `expiration:`.

- **`NostrRelayRouting` and `NostrListManaging` require only their primitives** (breaking):
  `publishRelayList(read:write:strategy:)` and `publishDirectMessageRelayList(relays:strategy:)` move
  to a protocol extension that builds the `RelayListMetadata` or `DirectMessageRelayList` and
  publishes it through `publishRelayList(_:strategy:)` or `publishDirectMessageRelayList(_:strategy:)`,
  and `fetchSet(naddr:timeout:)` moves to one that fetches the coordinate's kind, identifier, and
  author through `fetchSet(kind:identifier:for:timeout:)` — the author is named, so private items
  stay encrypted and relay hints stay unused, as before. The extensions also add short forms with
  the old defaults: `fetchRelayList(for:)`, `fetchDirectMessageRelayList(for:)`,
  `publishRelayList(_:)`, `publishDirectMessageRelayList(_:)`, `publishGossip(_:)`,
  `subscribeOutbox(authors:kinds:)` and `subscribeOutbox(authors:kinds:limit:)` for a non-optional
  `Int`, `publish(_:)`, `publishSet(_:)`, and, for `fetch`, `fetchSet`, and `fetchSets`, a form
  without `for:` (the current user) and one taking a non-optional `PublicKey`. An optional
  `publicKey`, `limit`, or `timeout` therefore needs every argument spelled out: `for: nil` alone no
  longer compiles — omit it.

- **`NostrGroupManaging` publishes through one primitive** (breaking):
  `publish(_:in:strategy:)` signs any `EventTemplate` and publishes it to the group's relay only,
  adding and connecting it on demand after signing, as every group write did. `join`, `leave`,
  `publishMessage`, and `publishModeration` move to a protocol extension that publishes
  `groupJoinRequest`, `groupLeaveRequest`, `groupContent`, and `groupModeration` templates through
  it, with the same tags, defaults, and errors. The reads and the kind-10009 list stay requirements,
  and the extension adds short forms with the old defaults: `publish(_:in:)`,
  `fetchMetadata(for:timeout:)` and `fetchState(for:timeout:)` plus forms taking a non-optional
  `authorPublicKey`, `timeline(_:)`, `timeline(_:kinds:since:limit:)` for non-optional `kinds`,
  `timeline(_:since:limit:)`, `timeline(_:limit:)`, `fetchSimpleGroupList(timeout:)`,
  `fetchSimpleGroupList(for:timeout:)` for a non-optional `PublicKey`, and
  `publishSimpleGroupList(_:)`. An optional `authorPublicKey`, `kinds`, `since`, or `publicKey`
  therefore needs every argument spelled out.
- **`WalletConnectMethod` and `WalletConnectErrorCode` are open types** (breaking): NIP-47 adds
  methods and error codes over time, so both are `RawRepresentable` structs with a non-failable
  `init(rawValue:)`, the current methods and codes as static constants under the same names, and a
  bare JSON string encoding. `WalletConnectMethod` is no longer `CaseIterable`, and
  `WalletConnectErrorCode.unknown(_:)` is gone: a code NIP-47 does not define is
  `WalletConnectErrorCode(rawValue:)`. `WalletInfo.methods` keeps every token the wallet advertises,
  recognized or not, and `WalletInfo.unknownMethods` is removed.
  `WalletConnectError.unexpectedResultType(expected:received:)` carries `WalletConnectMethod`
  values instead of strings.
- **NIP-47 parameter types are request types** (breaking): each single-response command's
  parameters conform to `WalletConnectRequest`. `PayInvoiceParams` is `PayInvoiceRequest`,
  `PayKeysendParams` is `PayKeysendRequest`, `MakeInvoiceParams` is `MakeInvoiceRequest`,
  `LookupInvoiceParams` is `LookupInvoiceRequest`, and `ListTransactionsParams` is
  `ListTransactionsRequest`; `EmptyParams` is replaced by `GetBalanceRequest` and `GetInfoRequest`.
  The multi-payment bodies draw one response per item, so they do not conform and are no longer
  public: `MultiPayInvoiceParams.Invoice` is `MultiPayInvoiceItem` and
  `MultiPayKeysendParams.Keysend` is `MultiPayKeysendItem`, which `multiPayInvoice(_:)` and
  `multiPayKeysend(_:)` take in arrays as before.

- **`RemoteSignerMethod` is an open struct** (breaking): it was a closed `enum` and is now a
  `RawRepresentable` struct over the wire token, with a non-failable `init(rawValue:)` and the same
  ten methods as static constants, so a method a signer implements beyond them can be named and
  sent with `RemoteSigner.send(_:params:)`. It encodes as a bare JSON string and its `description`
  is the token. `CaseIterable` is gone, and a `switch` over it needs a `default` case.
- **Tag queries are a `Filter[tag:]` subscript** (breaking): `filter[tag: .hashtag] = ["nostr"]`
  replaces `addTagQuery(_:values:)`, which replaced rather than added, and `filter[tag: .hashtag]`
  replaces `tagQuery(_:)`; assigning nil removes the query. The name is the tag name, so a leading
  `#` is no longer stripped: `"#t"` names a different tag than `"t"`. `filter[tag: .event]` and
  `filter[tag: .publicKey]` are the `#e` and `#p` queries behind `eventReferences` and
  `publicKeyReferences`, as hex strings; values set through the subscript are encoded as given, and
  the typed properties leave out any that are not canonical hex.
- **Protocol requirements whose conformers throw one error type use typed throws** (breaking for
  custom conformers, which must declare the same type): a call through the protocol now gets the
  concrete error instead of `any Error`. `NostrRelayManaging.connect()` and `connect(to:)`,
  `NostrSubscribing.subscribe(filters:to:bufferingPolicy:)` with its short forms, `events`, and the
  feeds, and `NostrRelayRouting.subscribeOutbox(authors:kinds:limit:)` with its short forms are
  `throws(RelayPool.Error)`; `NostrRelayRouting.connectDirectMessageInboxRelays()` is
  `throws(NostrClient.Error)`; and `RelayTransport`'s `connect()`, `subscribe(id:filters:)`, and
  `send(_:)` are `throws(RelayConnection.Error)`.
- **NostrWalletConnect and NostrConnect use typed throws** (breaking): `WalletConnection` and
  `WalletConnectURI` are `throws(WalletConnectError)`, and `RemoteSigner`, `BunkerURI`, and
  `NostrConnectURI` are `throws(RemoteSignerError)`, so a `catch .timedOut` needs no cast.
  Relay failures that used to escape as `RelayConnection.Error` are wrapped in the new
  `transportFailed(_:)` case of each. A cancelled task now fails a command, `fetchInfo()`, or
  `awaitConnection()` at once with the new `cancelled` case instead of `timedOut`, and a command
  from an already-cancelled task is not sent; `awaitConnection()` previously ignored cancellation.
  `RemoteSigner(bunker:)` no longer throws. `payZap(...)` stays untyped: it also throws
  `LNURLPayResponse.InvoiceError`.
- **NIP-19 and NIP-11 kinds are `Event.Kind`** (breaking): `NAddr.kind`, `NEvent.kind`, their
  initializers, `NIP19Entity.Error.kindOutOfRange`, `RelayInformation.FeeSchedule.kinds`, and the
  `RelayInformation.KindSpec` cases `.single` and `.range`. The wire format is unchanged.
- **Protocol URLs are `URL`** (breaking): `RelayInformation`'s `banner`, `icon`, `termsOfService`,
  `postingPolicy`, and `paymentsURL`; `LNURLPayResponse.callback`; `DirectMessageFile.url` and the
  `url:` of `EventTemplate.fileMessage`, `createFileMessageWithSelfCopy`, and `sendFile`; and
  `Tag.url(_:)` and `Tag.reference(_:)`. Each is written as its `absoluteString`. A NIP-11 URL that
  does not parse decodes as nil, an LNURL-pay response whose `callback` does not parse fails to
  decode, and a file message whose content does not parse is rejected with
  `DirectMessagePayload.Error.invalidFileURL`, which replaces `missingFileURL`.

### Fixed

- **A subscription or fetch whose targets are not in the pool no longer sends a stray CLOSE**:
  when none of the targeted relays was in the pool (`noMatchingRelays`), the client still sent `CLOSE`
  for the never-opened subscription to every relay in the pool. Nothing is sent now, so `fetchLongFormContent(naddr:)` falling back from relay
  hints that are not in the pool to the whole pool sends a single `REQ`.
- **Ending a subscription no longer reconnects relays to close it**: `RelayPool.unsubscribe` — run
  when a `for await` over a client subscription ends — sent `CLOSE` to every relay in the pool, and
  each disconnected, failed, or backing-off relay reconnected (blocking up to `connectionTimeout`)
  just to send it. `CLOSE` now goes only to the connected relays holding the subscription.
- **Unsubscribing while the REQ is still being sent ends the subscription**: `RelayConnection`
  recorded a subscription only once its REQ had gone out, so an `unsubscribe(subscriptionID:)` in
  that window found nothing to close and the REQ then registered it, leaving it open on the relay
  and replayed on reconnect. It is now recorded before the REQ is sent, and a REQ that fails to
  send restores what its ID held before unless a newer subscribe or unsubscribe has replaced it.
- **`EventSigner` no longer signs another key's event** (breaking): `sign(_:)` copied the
  `UnsignedEvent`'s public key into the result unchecked, so an event keyed to anyone else came back
  with an id and signature that could not verify. It now throws the new
  `EventSigner.Error.publicKeyMismatch`, and `NostrSigning.sign(_:)` requires every conformance to
  reject such an event; `RemoteSigner` already did, with `RemoteSignerError.responseValidationFailed`.
- **`#e` and `#p` tag queries round-trip**: a query set with `addTagQuery(.event, …)` or
  `addTagQuery(.publicKey, …)` was stored apart from `eventReferences` and `publicKeyReferences`,
  so a filter holding both wrote two values to the same `#e` or `#p` key, and decoding never
  restored the generic query. Each tag query now has a single value, encoded once.
- **Notification and auth-challenge streams finish when the relays' streams end**: once automatic
  reconnection gave up, `WalletConnection` and `RemoteSigner` failed their in-flight requests but
  left every `notifications()` and `authChallenges()` stream open, so a `for await` over one never
  ended. They now finish, as they do on `disconnect()`; call either method again for a fresh stream,
  which the next request (or `notifications()` itself) reconnects to serve.
- **`fetchInfo()` and `awaitConnection()` fail when the relays' streams end**: once automatic
  reconnection gave up, `WalletConnection.fetchInfo()` and `RemoteSigner.awaitConnection()` waited
  out their whole timeout for a reply that could no longer arrive. They now throw
  `WalletConnectError.notConnected` and `RemoteSignerError.notConnected` at once, as on
  `disconnect()` and like the in-flight requests the connection fails.
- **`EventSigner` signs a template without `await` in async code** (breaking for `NostrSigning`
  conformers): in an async context Swift preferred the async `NostrSigning.sign(_:)` extension
  method over `EventSigner`'s synchronous `sign(_:)`, so `try signer.sign(.textNote("gm"))` on an
  `EventSigner` failed to compile without `await`. `sign(_ template: EventTemplate)` is now a
  `NostrSigning` requirement with no default implementation, which `EventSigner` satisfies
  synchronously; a third-party conformance must implement it, typically as
  `try await sign(UnsignedEvent(template, publicKey: publicKey))`. `RemoteSigner` implements it.

## [0.8.0] - 2026-10-25

A hardening release. A review of the whole package fixed more than thirty defects — relay
connections that could wedge or leak, subscriptions that missed or double-delivered events,
NIP-46 and NIP-47 sessions that trusted unverified or mismatched responses, and encoders and
decoders that accepted non-canonical input. Alongside the fixes, NIP-44 encryption is reachable
through any signer and under a caller-supplied conversation key, a rumor of any kind can be
delivered gift-wrapped, a signed event can be published to chosen relays, and a `bunker://`
session can request permissions up front. Upgrading from 0.7.0 requires source changes for
conforming types, NIP-47 multi-pay results, and stricter NIP-57 zap validation; see **Changed**.

### Added

- **`NostrIdentityAPI.nip44Encrypt(_:to:)` and `nip44Decrypt(_:from:)` encrypt through the active
  signer**: an app whose key lives in a NIP-46 bunker could reach NIP-44 only inside the
  direct-message path, so it had no way to encrypt its own payloads to a peer. Both route through
  the signer set on `client.identity`, local or remote, and throw `signerNotSet` without one. With
  a remote signer each call is a relay round-trip.
- **`NostrMessagesAPI.sendGiftWrapped(_:to:expiration:strategy:)` delivers a rumor of any kind
  gift-wrapped**: the rumor is wrapped for the recipient and as a self-copy and routed exactly like
  `send` — each addressee's kind-10050 DM relays, falling back to the pool. Private payloads other
  than kinds 14, 15, and 7 no longer need the routing reimplemented. A rumor whose `pubkey` is not
  the signer's throws `invalidPublicKey`, since the recipient's unwrap would reject it.
- **NIP-44 encryption under a caller-supplied conversation key**:
  `SealedMessage.seal(_:conversationKey:)` and `open(conversationKey:)` take the 32-byte conversation
  key directly instead of deriving it from a key pair, so one ciphertext can be read by everyone
  holding a shared key. The payload is standard NIP-44 v2 and a fresh random nonce is generated per
  message; the nonce is not exposed, so callers cannot reuse one. Anyone holding the key can both
  read and forge messages under it.
- **`NostrEventsAPI.publish(_:to:strategy:)` publishes an already-signed event to chosen relays**:
  `publish(_:strategy:)` only broadcast to the whole pool, so an event signed by a separate key and
  meant for a small named relay set could not be routed through the public API, unlike `fetch`,
  `count`, and `subscribe`, which already took `to:`. Targets are normalized and de-duplicated like
  pool keys, relays not in the pool are skipped rather than connected, and an empty list throws
  `noMatchingRelays` instead of falling back to the whole pool. Passing nil (the default) broadcasts
  as before.
- **A `bunker://` session can request permissions**: `RemoteSigner(bunker:clientKeyPair:requesting:…)`
  takes the `[RemoteSignerPermission]` to ask for, and sends them in NIP-46's `connect` call. They
  were modeled but never sent, so a session could not pre-authorize anything and every operation drew
  its own interactive `auth_url` round-trip. A `nostrconnect://` session is unchanged: its permissions
  travel in the invitation URI the signer reads, and the client sends no `connect` at all, so the two
  flows stay separate. Requesting nothing keeps the previous wire shape.

### Changed

- **`NostrIdentityProviding` requires `nip44Encrypt(_:to:)` and `nip44Decrypt(_:from:)`**
  (breaking): conforming types outside the package must implement both.
- **`NostrMessaging` adds the requirement `sendGiftWrapped(_:to:expiration:strategy:)`**
  (breaking): conforming types outside the package must implement it.
- **The `NostrEventPublishing` requirement `publish(_:strategy:)` is now `publish(_:to:strategy:)`**
  (breaking): conforming types outside the package must add the `to relayURLs: [String]?` parameter.
  Call sites are unchanged, since `NostrEventsAPI` defaults it to nil.
- **`multiPayInvoice` and `multiPayKeysend` return `MultiPayResults` instead of a dictionary**
  (breaking): results were keyed by the response's `d` tag, which cannot identify a request item —
  two responses sharing a tag silently overwrote each other, and an item sent without an `id` is
  answered under a payment hash this package cannot derive from an invoice, so its result could not
  be tied back at all. The new type carries one outcome per item **in the order requested**, and
  anything that could not be matched — an unknown `d` tag, a duplicate of one already claimed —
  appears in `unmatched` rather than being dropped; those payments still happened. Items the wallet
  never answered are `.noResponse`, listed by `indicesWithoutResponse`. **Migration:** iterate
  `results.outcomes` by index instead of subscripting by id, and give every item an `id` so its
  response can be matched. An empty item list now returns immediately rather than waiting out the
  full request timeout.
- **NIP-57 zap receipt validation reports checks it cannot make**: `ZapReceipt.validate` skipped a
  check whenever the tag it needed was absent, so a receipt could pass having established only that
  the provider's key signed something. It now requires the `p` tag NIP-57 mandates, rejects a
  non-numeric `amount` instead of reading it as absent, and fails when `expectedAmountMillisats` is
  given for an invoice that names no amount — the assertion the caller asked for cannot be made
  against one. It also requires the invoice to commit to the zap request through its description
  hash, the binding that ties the invoice paid to the zap requested; a new
  `requiringDescriptionHash` parameter (default `true`) relaxes that for a provider known to omit
  it. Four new `ValidationError` cases accompany this: `missingDescriptionHash`, `missingAmount`,
  `invalidAmount`, and `missingRecipient`.
- **NIP-49 bounds its scrypt cost on both sides**: `EncryptedPrivateKey.encrypt(…)` takes a
  `maximumLogN` and `decrypt(password:)` / `KeyPair(ncryptsec:password:)` take a `maxLogN`, both
  defaulting to
  `EncryptedPrivateKey.defaultMaximumLogN` (18, or 256 MiB). scrypt's memory cost is `128 · N · r`
  and NIP-49 fixes `r` at 8, so the cost byte a payload records decides the allocation on its own —
  4 GiB at the spec's maximum of 22, which the system terminates before the password is even
  checked. The default sits two doublings above the 16 the spec recommends, so ordinary keys are
  unaffected; a caller who must write or open a deliberately costlier key raises the corresponding
  bound and accepts the allocation. The writer is capped by the same default as the reader, so this
  library never mints an `ncryptsec` it would then refuse to open. A parsed payload's `logN` is
  readable beforehand, so that choice can be made with the real number in hand.

- **Minimum dependency versions rise to swift-crypto 5.0.0 and swift-secp256k1 0.24.0**: the
  secp256k1 release builds for Wasm and drops products this package never used.

### Fixed

- **A hostile timestamp no longer crashes the process**: a `published_at` or NIP-40 `expiration`
  tag is parsed from the full `Int64` range, but `Date` stores a `Double` and converting one back
  with `Int64(_:)` traps on a value it cannot represent. Reading a long-form article or a direct
  message with an extreme timestamp and then re-emitting it — the documented edit-and-republish
  flow — killed the process. Timestamps are clamped to the range that round-trips, so a nonsense
  value stays nonsense instead of becoming a crash.
- **Relay URLs from a wallet URI and from `switch_relays` are checked for a WebSocket scheme**: a
  `nostr+walletconnect://` URI accepted `https://` or `file://` relays, and `RelayConnection`'s
  URL-taking initializer does not validate the scheme the way its string form does, so they were
  connected to as written. NIP-46's `switch_relays` response had the same gap, and silently dropped
  unparseable entries rather than reporting a malformed response. Both now match the validation
  `bunker://` and `nostrconnect://` URIs already applied.
- **A terminal drop ends the message streams even when nothing will reconnect**: with
  `autoReconnect` disabled, a keepalive or send failure discards the socket, which retires the
  generation the receive loop runs under — so the loop exited without finishing the streams and
  nothing else did either, leaving a `for await` over `messages()` waiting forever. The drop is now
  recognized as terminal where the reconnect is declined, matching what already happened when
  auto-reconnect gave up after its last attempt.
- **A disconnected relay connection can no longer wedge as "connected"**: a connection attempt
  suspends while it waits for the pong that proves its socket works, and `disconnect()` (or a later
  attempt) could discard that socket meanwhile. The attempt resumed regardless and marked the
  connection `.connected` with no socket installed, no receive loop, no keepalive, and no reconnect
  pending. Since `connect()` returns early while the state says connected, the connection could
  never be revived: every later `send` and `publish` threw for the lifetime of the object. Each
  socket now carries a generation that the connect attempt, receive loop, keepalive, and in-flight
  sends compare before touching shared state, so work belonging to a superseded socket stops
  instead of landing on the live session. Reachable from ordinary use — `RelayPool.disconnectAll()`
  or `removeRelay` overlapping `connectAll()`.
- **Disconnecting ends every open subscription instead of hanging its consumer**:
  `client.relays.disconnect()` cancelled the pool's listener tasks but left the client's
  subscription sequences open, so a `for await` over one never ended and never received anything
  again — nothing recreates the listeners, and each connection clears its own tracked subscriptions
  on disconnect, so reconnecting restored the sockets but not the delivery. Disconnecting now ends
  the sequences first, from the client layer that owns them. The pool's handler and deduplication
  state are dropped with the listener tasks as well; retained, they grew on every
  connect/disconnect cycle while naming subscriptions the pool could no longer serve.
- **Re-subscribing under an id already in use no longer double-delivers**: cancelling the previous
  listener tasks does not stop a frame already in flight, and the listener resolved the handler at
  delivery time — so a straggler from the old generation was handed to the *new* handler, and every
  EOSE, CLOSED, NOTICE, and AUTH arrived twice. Each listener now carries the generation it belongs
  to and delivers only while it is current.
- **A subscription can no longer miss the events that answer it**: the listener was started in a
  detached task and the REQ was sent after a bare `Task.yield()`, which does not guarantee the
  listener had registered its stream. Anything the relay sent immediately — including the EOSE a
  fetch waits for — could be dropped, leaving the fetch to wait out its whole timeout. The stream is
  now obtained before the REQ is sent, so registration is complete rather than merely likely.
- **A duplicate request key is refused instead of hanging its first caller**: registering a request
  under a key already in flight overwrote the entry, dropping the first request's continuation
  without resolving it and leaving its timeout running. That caller stayed suspended forever — its
  own cleanup never runs, because it never returns — while the orphaned timeout resolved the second
  request on the first one's schedule. A `RequestResponseSessionError.duplicateRequestKey` is thrown
  now; the request already in flight is untouched, and the key becomes reusable once it completes.
- **A NIP-46 or NIP-47 session recovers when its relays stop delivering**: the session's event stream
  ends once every relay's has — automatic reconnection giving up, or the connections going away —
  but the session went on reporting itself started. Requests already in flight waited out their
  whole timeout instead of failing, and every later request was sent into a transport that could not
  answer, timing out in turn with nothing to say why. In a test an in-flight request took its full
  60-second timeout and then reported a timeout rather than a disconnection. The session now fails
  what is pending with its `notConnected` error and clears its started state, so the next request
  reconnects. `RelayTransport` is unchanged — its `events()` stays a non-throwing `AsyncStream`.
- **A re-challenging relay no longer triggers overlapping AUTH answers**: the receive loop answered
  every NIP-42 `AUTH` frame, without the checks `setAuthenticationResponder` applies before starting
  an answer of its own. A relay that challenges again — on reconnect, on a policy change, or simply
  repeatedly — produced a second signed AUTH for an already-authenticated session, and concurrent
  answers made `isAnsweringChallenge` unreliable, since whichever finished first cleared it for all.
- **Reconnection backoff is bounded and jittered**: `initialReconnectDelay: 0` reads like "reconnect
  immediately", but zero multiplied by any backoff stays zero — and with the default of unlimited
  attempts that was an unbounded loop with no pause at all, reaching over 16,000 connection attempts
  in 300 ms in a test. A negative delay behaved the same, since `Task.sleep` of one returns at once,
  as did a multiplier at or below zero. Delays are now floored and capped where they are read rather
  than validated in the initializer, since every configuration field is a `var` and a value assigned
  afterwards would bypass validation done at init time. Each wait is also scaled by a random factor
  between a half and one, so relays behind one failing uplink no longer retry in lockstep.
- **Disconnecting a failed connection runs the full teardown**: `.failed` is the state a connection
  sits in after any dropped connection, and `disconnect()` returned early from it before doing any
  cleanup. In-flight `publish` and `count` callers were left waiting out their timeouts — up to 30
  seconds on a connection already gone — instead of failing immediately with
  `NostrError.notConnected`; tracked subscriptions survived to be replayed on the next `connect()`,
  resurrecting subscriptions the caller believed were closed; and NIP-42 state persisted, so
  `isAuthenticated` reported `true` for a session that no longer existed. The teardown is now the
  same from every state. Disconnecting an already-disconnected connection also no longer announces
  a second `.disconnected` transition to `stateChanges()` consumers.
- **Sockets are closed when replaced, and receive loops stop with their socket**: a failed send left
  its socket installed, so the next connection attempt overwrote a live connection nobody closed and
  its receive loop kept running beside the new one — both loops then reporting the same session's
  death. The receive loop is also held and cancelled on teardown; it previously kept the connection
  object alive indefinitely by capturing it while parked in `receive()`.
- **NIP-05 identifiers split on the last `@` and validate the local part**: `alice@evil.com@example.com`
  split on the first `@` and resolved against the host `evil.com@example.com` rather than being
  rejected, disagreeing with `LNURL`, which already split on the last one. NIP-05 allows only
  `a-z0-9-_.` in a local part, so an identifier carrying a second `@` is malformed however it is
  split, and is now refused along with local parts and domains that could not appear in a URL.
- **NIP-19 bare entities validate their payload when encoding**: `npub`, `nsec`, and `note` hold a
  hex string that nothing checks on the way in, and encoding substituted an empty payload for
  invalid hex — so `try NIP19Entity.npub("not-hex").encoded` returned a checksum-valid `npub1…`
  naming nobody, which reads as a real key wherever it is shown or stored. It now throws
  `NostrError.invalidNIP19Entity`.
- **Replies find the thread root by its NIP-10 marker position**: `publishReply` compared every
  element of an `e` tag against `"root"`, so a tag explicitly marked `"reply"` whose relay hint read
  `"root"` was carried over as the thread root. A parent written in NIP-10's deprecated positional
  form — no markers at all — looked rootless, and the reply started a second thread beside the one
  it was answering; its first `e` tag is now used as the root, as the spec says.
- **Derived key material is zeroed once it is no longer needed**: the NIP-44 conversation and
  message keys, the ECDH shared point they come from, the padded plaintext buffers, and the NIP-49
  scrypt key are scrubbed on the way out of the operations that derive them, narrowing the window in
  which freed memory still holds a usable key. This is defense in depth, not a guarantee: `Data` is
  copy-on-write, so a copy that has already diverged is untouched, and `String`-typed secrets such as
  a mnemonic or a decrypted `nsec` cannot be scrubbed at all. Both limits are documented on the
  helper rather than left implied.
- **Repeated NIP-46 auth challenges cannot extend a request without end**: each `auth_url` replaced
  the request's timeout, so a signer that kept sending them held the caller suspended indefinitely.
  The first challenge now fixes a deadline and later ones may only postpone up to it, keeping the
  wait within the configured `authChallengeTimeout` however many arrive.
- **NIP-46 connection secrets are compared in constant time**: both the `bunker://` acknowledgement
  and the `nostrconnect://` invitation echo used `==`. These are short-lived secrets carried over a
  relay so exploitation was impractical, but a secret comparison is the wrong place for a shortcut.
- **Wallet events are verified, and responses decrypted by the scheme they declare**: every event
  from the wallet is now checked against its signature before anything in it is read — the author
  was already checked, but a response carrying the wallet's pubkey and no valid signature was
  accepted outright. Responses are also decrypted with the scheme named in their own `encryption`
  tag rather than the one the request happened to use, so a wallet answering in NIP-04 can be read
  at all. That includes its `UNSUPPORTED_ENCRYPTION` error, which previously could not be decrypted
  and surfaced as a generic `responseDecodingFailed` with nothing pointing at the cause. A response
  with no tag still falls back to the request's scheme, and one naming a scheme this package does
  not implement reports `WalletConnectError.unsupportedEncryption`.
- **A wallet response delivered over several relays is counted once**: a NIP-47 connection URI may
  list several relays, and this path merges them without deduplicating — that only happens in
  `RelayPool`, which the wallet transport bypasses. One response arriving over two relays counted
  twice, so a `multi_pay_*` completed early with a duplicate result while the response it was still
  owed had nowhere to go: the caller was told an invoice had no result when it may have been paid.
- **A wallet response naming another command is not folded in**: the `result_type` a response
  declares was never checked, so a reply to a different command satisfied the request whenever its
  body happened to decode. A single-response command now reports
  `WalletConnectError.unexpectedResultType`.
- **Fetched replaceable and addressable events are verified before they are believed**: a relay may
  answer a filter with anything, and these fetches took the newest event they were handed — so a
  forged copy dated far ahead won outright, since newer always displaces older. The DM relay list
  (kind 10050) is the sharpest case: it decides where a user's private messages are delivered, so a
  forged one routed every gift wrap to relays the attacker chose, and the recipient never received
  the message. The NIP-65 relay list, profile metadata, lists and sets, and long-form articles were
  all reachable the same way, and `fetchEvent(id:)` returned whatever a relay sent for an id filter
  it ignored. Every such fetch now selects through one helper that checks the author, kind, `d`
  identifier where the coordinates include one, and the signature, and breaks a `created_at` tie on
  the lowest id as NIP-01 prescribes. `fetchMetadata` additionally picks the newest profile rather
  than whichever copy arrived first.
- **Gift-wrapped messages authenticate their sender (NIP-17)**: `GiftWrap.unwrap` verified the
  seal's signature but never checked that the rumor inside named the same author, which NIP-17
  requires precisely because "any sender can impersonate others by simply changing the pubkey on
  kind:14". The rumor is unsigned by design, so its `pubkey` was whatever the sealer wrote: a
  message could arrive whose `senderPubkey` was the real sender while the returned event named
  someone else as its author, and anything storing or re-serializing that event attributed the
  message to the wrong person. The rumor's `id` was likewise trusted verbatim, though it is the key
  `DirectMessage` and `DirectMessageReaction` correlate on — a sender could pick one that collides
  with a message from another conversation. Both are now checked, so `senderPubkey`, the event's
  `pubkey`, and its `id` are all attested by the seal's signature.
- **Event verification rejects malformed keys and signatures**: `Event.verify()` now checks that the
  `pubkey` decodes to 32 bytes and the `sig` to 64 before handing them to libsecp256k1, which parses
  both as fixed-width buffers without validating their length. A short `pubkey` previously caused a
  read past the end of the decoded buffer, and a long one was silently truncated to its first 32
  bytes, so a single key could be spelled many ways and slip past checks keyed on the pubkey string.
  Both fields arrive straight from a relay, so the mismatch is remotely reachable on any verification
  path — NIP-98 HTTP auth, gift-wrap seals, zap receipts, group state, and NIP-46 responses. Wrong
  lengths now throw `NostrError.invalidPublicKey` / `.invalidSignature` instead of returning `false`
  or surfacing the underlying secp256k1 error type.
- **Hex decoding rejects sign characters**: `Data(hexString:)` delegated each byte to
  `UInt8(_:radix:)`, which accepts a leading `+` or `-`, so `"+1"` decoded to `0x01`. Distinct
  strings could decode to the same identity, desynchronizing any cache, mute list, or comparison
  keyed on the hex spelling. Only ASCII hexadecimal digits are accepted now.
- **Bech32 decoding enforces the canonical spelling (BIP-173)**: `Bech32.decode(_:)` discarded the
  bits left over after regrouping without checking them, so every `npub`, `nsec`, `note`, or
  `ncryptsec` had sixteen checksum-valid spellings that all decoded to the same payload. It now
  rejects a payload whose leftover bits number five or more or are not zero. `Bech32.decodeToWords`
  and `Bech32.wordsToBytes` keep their lenient regrouping for formats sliced into fields that are
  not individually byte-aligned, such as BOLT-11 invoices.
- **Bech32 decoding rejects mixed case**: BIP-173 forbids mixing upper and lower case in one string;
  the case was folded before any check, so mixed-case input decoded. All-lowercase and all-uppercase
  input — the latter common in QR codes — remain valid on both `decode(_:)` and `decodeToWords(_:)`.
- **Bech32 encoding validates the human-readable part**: `Bech32.encode(hrp:data:)` accepted an
  empty or uppercase prefix and produced a string that `decode(_:)` could never accept, since the
  checksum covered the prefix as written while decoding recomputes it lowercased. The prefix must
  now be non-empty lowercase printable ASCII.
- **NIP-13 difficulty counts only ASCII hex digits**: `Character.hexDigitValue` also resolves the
  Halfwidth and Fullwidth Forms of the hex digits, so an id written in fullwidth zeros reported the
  maximum difficulty of 256 and satisfied `ProofOfWork.validate(event:minimumDifficulty:)`. A client
  that filters on proof of work before verifying the id — the natural order, since the hash is the
  cheap check — accepted such an event as maximally mined. Counting now stops at the first character
  that is not an ASCII hex digit.
- **NIP-44 rejects a wrong-length conversation key or nonce**: HKDF accepts inputs of any length, so
  `SealedMessage.encrypt`/`decrypt` would expand a malformed key or nonce into a well-formed payload
  that nobody could decrypt — a failure surfacing only on the recipient's side. Both now throw.
- **Uppercase filter tag queries reach the relay intact**: `REQ` and `COUNT` messages were encoded
  with a snake-case key strategy that rewrote the dynamic keys behind `Filter.addTagQuery(_:values:)`
  — the uppercase single-letter tags NIP-22 uses for root scope became `#_k` and friends. A relay
  drops a tag-query key it does not recognize and answers the rest of the filter, so the query
  silently returned more events than it asked for rather than failing. The strategy was a no-op for
  every declared key, which already spells itself as it appears on the wire, and is gone.

## [0.7.0] - 2026-07-26

An API-shape release: `NostrClient`'s ~70 methods move onto eight feature namespaces backed by
capability protocols, every client feature runs through the `NostrSigning` abstraction so a remote
signer drives all of them, and the relay layer consolidates into `NostrCore` with normalized,
string-based targeting and an injectable WebSocket transport. Two NIPs join the supported set —
NIP-98 HTTP Auth and NIP-29 relay-based groups — and NIP-44 gains strict padding validation and the
official vector suite. Upgrading from 0.6.0 requires source changes; see **Changed**.

### Added

- **Client feature namespaces**: `NostrClient`'s API is now reached through eight namespaces —
  `identity`, `relays`, `events`, `subscriptions`, `routing`, `messages`, `groups`, and `lists` —
  instead of ~70 methods on the client itself, so completion shows one feature area at a time and
  adding a NIP no longer widens the root type. Each namespace is a `Sendable` value holding only
  the client, free to read, store, or hand to a background task.
- **Capability protocols**: each namespace conforms to a protocol describing just that slice —
  `NostrIdentityProviding`, `NostrRelayManaging`, `NostrEventPublishing`, `NostrEventFetching`,
  `NostrSubscribing`, `NostrRelayRouting`, `NostrMessaging`, `NostrGroupManaging`, and
  `NostrListManaging` — so an app feature can declare `any NostrMessaging` rather than the whole
  client and be tested against a stub. Swift forbids default arguments on protocol requirements,
  so the protocols spell out every parameter; the concrete namespaces still supply the defaults.
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
  `GroupState` snapshots, and `NostrClient` flows — `groups.join`, `groups.leave`,
  `groups.publishMessage`, `groups.publishModeration`, `groups.fetchMetadata`/`groups.fetchState`
  with relay-author validation, and `groups.timeline` — all scoped to the group's relay.
- **NIP-29 Relay-based groups (group list)**: the NIP-51 kind-10009 simple group list as a typed
  `SimpleGroupList`/`GroupListEntry` view over `NostrList` — including NIP-44 private entries —
  with `groups.fetchSimpleGroupList` and `groups.publishSimpleGroupList` on `NostrClient`.
- **Official NIP-44 vectors**: the canonical vector file from
  [paulmillr/nip44](https://github.com/paulmillr/nip44) is bundled as a test resource and run in
  full — conversation keys, message-key derivation, the padding table, every `encrypt_decrypt`
  payload and its maximum-length variants, and every rejection case — replacing the four
  hand-copied vectors that previously stood in for the suite.
- **Transport injection on a single relay**: the designated
  `RelayConnection(url:webSocketFactory:config:)` initializer is now public, so a host can drive one
  relay connection on a platform-native socket (for example an OkHttp-backed
  `WebSocketSessionFactory` on Android) or on an in-memory fake — matching the injection `RelayPool`
  and `NostrClient` already expose.
- **Transport injection in a NIP-46 or NIP-47 session**: the shared `RelayConnectionTransport` now
  takes a `webSocketFactory:` and a `config:`, so a remote-signer session or a wallet connection can
  run its relays on a platform-native socket or an in-memory fake and tune their timeouts, keepalive,
  and reconnection. Neither was reachable before: the per-module transports it replaces hard-coded
  `URLSession` and `RelayConnectionConfig.default`.
- **String-based relay conveniences**: `client.events.count(filters:to:timeout:)` scopes a NIP-45
  count to a subset of relays; `client.relays.remove(_:)` removes a relay by URL string;
  `client.relays.add(_:config:)` accepts a per-relay `RelayConnectionConfig`; and
  `PublishResult.status(for:)` looks up a relay's publish status from any spelling of its URL
  string, resolved against the result's canonical keys.

### Fixed

- **NIP-44 padding is now validated strictly.** Decryption accepted any padded block long enough
  to hold the declared plaintext, so a payload carrying a valid MAC over non-canonical padding
  decrypted successfully. The block must now be exactly the 2-byte length prefix plus
  `calc_padded_len` of the declared length, matching the reference implementation; anything else
  throws `NostrError.invalidPadding`. Payloads produced by this or any other compliant
  implementation are unaffected.
- The decoded-payload size check in NIP-44 decryption used a minimum of 97 bytes, derived from a
  comment that undercounted the smallest ciphertext. The bounds are now the correct 99 to 65,603
  bytes, so more malformed payloads are refused before any key derivation.
- **`fetch` no longer idles its full timeout when nothing was targeted.** With zero resolved
  relays the fetch waited the entire timeout (default 10s) and then returned `[]`; it now fails
  fast with the new zero-relay errors (see Changed).
- **Duplicate sockets for differently-spelled URLs of the same relay.** The pool keyed
  connections by the raw `URL`, so `wss://Relay.Example.com/` and `wss://relay.example.com`
  produced two entries and two sockets to one relay; connections are now keyed by the
  normalized URL.
- **`RelayPool.subscribe` leaked state when every REQ send failed.** The subscription handler
  and the per-relay message-listener tasks stayed registered after the throw; a totally failed
  subscribe now removes the handler and cancels the listeners before surfacing the error.
- **Event deduplication dropped events from every subscription but the first.** The pool kept a
  single cache keyed only by event ID, so an event matching two subscriptions reached only
  whichever one processed it first — overlapping feeds silently lost events, and a repeated
  `fetch` of the same event returned it once and then nothing. Deduplication is now scoped per
  subscription, so cross-relay copies still collapse into a single delivery while every
  subscription receives its own; a subscription's history is discarded on `unsubscribe`.
- **`maxDeduplicationCacheSize` did not actually bound the deduplication cache.** The limit was
  applied only by a sweep that ran at most once a minute, so the cache grew without bound in
  between and settled one entry above the limit even right after a sweep. It is now enforced as
  each event is recorded, evicting the oldest entries, so the bound holds at all times.
- **`RelayPool.removeRelay` raced a concurrent re-add of the same relay.** The pool entry was
  removed only after the disconnect suspended, so an add interleaving with the removal
  could receive a connection about to be torn down; the entry is now removed first.
- **A relay listed for both reading and writing under different spellings lost a direction.**
  `EventSigner.signRelayListMetadata(read:write:)` and `client.routing.publishRelayList(read:write:)`
  compared the two lists as raw strings, so `wss://relay.example.com/` in `read` and
  `wss://relay.example.com` in `write` were treated as two relays and emitted as two conflicting
  `r` tags, which any NIP-65 reader collapses to whichever came first. Membership is now decided
  on the normalized URL, so equivalent spellings produce a single read+write entry that keeps the
  spelling and position of its first appearance.
- **A concurrent NIP-47 command could publish before the wallet connection was subscribed.**
  `WalletConnection` guarded its lazy setup with a bool set before the first `await`, so a command
  issued while the first one was still connecting fell straight through the guard and sent its
  request — before the connection was established and the response subscription existed, losing
  any response the wallet sent in that window. Both NIP-46 and NIP-47 sessions now run that setup
  as one shared task, so a concurrent caller awaits the same connect/subscribe work instead of
  racing past it.

### Changed

- **Breaking**: every pre-namespace method and property on `NostrClient` — `publishTextNote`,
  `subscribe`, `fetch`, `sendDirectMessage`, `joinGroup`, `publishList`, `setSigner`, `connect`,
  `relayPool`, and the rest — is removed; each moves onto its namespace. Most keep their name
  (`client.publishTextNote(…)` → `client.events.publishTextNote(…)`). The renames that drop a
  prefix the namespace now supplies are: `sendDirectMessage` → `messages.send`,
  `reactToDirectMessage` → `messages.react(to:…)`, `sendFileMessage` → `messages.sendFile`,
  `parseDirectMessage`/`…Reaction`/`…File`/`…Payload` →
  `messages.parse`/`parseReaction`/`parseFile`/`parsePayload`, `directMessages` →
  `messages.subscribe`, `directMessagePayloads` → `messages.payloads`,
  `subscribeToDirectMessages` → `messages.giftWraps`, `joinGroup`/`leaveGroup` →
  `groups.join`/`groups.leave`, `publishGroupMessage`/`publishGroupModeration` →
  `groups.publishMessage`/`groups.publishModeration`, `fetchGroupMetadata`/`fetchGroupState` →
  `groups.fetchMetadata`/`groups.fetchState`, `subscribeToGroupTimeline` → `groups.timeline`,
  `publishList`/`fetchList` → `lists.publish`/`lists.fetch`, `addRelay`/`addRelays` →
  `relays.add`, `removeRelay` → `relays.remove`, and
  `subscribeToUserTimeline`/`…GlobalFeed`/`…Mentions`/`…Metadata` →
  `subscriptions.userTimeline`/`globalFeed`/`mentions`/`metadata`.
- **Breaking**: `NostrClient.relayPool` is now reached as `client.relays.pool`, which resolves
  the duplicate relay surface the client carried — the pool was public *and* the client forwarded
  `addRelay`/`connect`/`disconnect` alongside it. `client.relays` is the single relay entry point:
  it covers membership, the connection lifecycle, and pool inspection (`connections`, `count`,
  `connectedCount()`, `relay(for:)`), with `relays.pool` as the escape hatch for the per-relay
  detail it flattens. The pool is deliberately absent from `NostrRelayManaging`: it carries
  publish, subscribe, and count too, which a relay-management dependency has no business
  reaching, and requiring it would force every stub to stand up a real `RelayPool`.
- **Breaking**: a remote NIP-46 signer now drives every `NostrClient` feature, not just the
  generic paths. The convenience `publish*` helpers, NIP-17 direct messages (send, react, file
  messages, and parsing), and NIP-51 private list/set items previously threw
  `NostrError.localSignerRequired` for a remote signer, because they reached past `NostrSigning`
  for a raw private key; they now build their events from the signer's public key and go through
  `sign`/`nip44Encrypt`/`nip44Decrypt`, which every signer already provides. Nothing in the
  library needs a local key any more, so `NostrError.localSignerRequired` is removed — a source
  break for code that switches over `NostrError` exhaustively or matches that case.
  `DirectMessageSequence` and `DirectMessagePayloadSequence` are throwing async sequences as a
  result — iterate them with `for try await`. They still skip gift wraps that are not readable
  messages for the signer (sealed to someone else, or malformed), which is routine on a shared
  gift-wrap stream, but a signer that could not *attempt* the read now throws instead. With a
  remote signer every unwrap is a relay round-trip, so swallowing those would consume genuine
  messages from the stream and leave the caller unable to notice or resubscribe.
  Gift wrapping is the API this surfaces in: `GiftWrap.wrap(event:signer:recipientPubkey:)` and
  `GiftWrap.unwrap(giftWrap:recipient:)` take an `any NostrSigning` in place of a `KeyPair` (pass
  `EventSigner(keyPair:)` for a local key) and are now `async`, as are `DirectMessageBuilder` and
  `DirectMessageParser`, whose initializers take `signer:` instead of `keyPair:`. The outer gift
  wrap key stays ephemeral and locally generated; only the seal goes through the signer.
- **Single import**: `NostrClient`, `NostrWalletConnect`, and `NostrConnect` now re-export
  `NostrCore`; a separate `import NostrCore` is no longer required to use the primitives
  (`Event`, `KeyPair`, `Filter`, …) they surface.
- The package enables the `ExistentialAny` upcoming feature on every target, and CI compiles
  with `-warnings-as-errors` on the Linux and macOS jobs, so implicit existential spellings and
  new compiler warnings now fail the build instead of accumulating. No effect on consumers of
  the library.
- `RemoteSigner.awaitConnection()` now throws a distinct `RemoteSignerError.connectionInProgress`
  when another wait is already running on the session, instead of conflating that with
  `.notConnected`. The new case is additive but a source break for code that switches over
  `RemoteSignerError` exhaustively.
- **Breaking**: `Contact.relayUrl` is now `Contact.relayURL`, matching the `relayURL` spelling of the
  tag API it feeds (`Tag.pubkey(_:relayURL:petname:)`) and the Swift API Design Guidelines rule that
  acronyms are uniformly cased. The `relayUrl:` argument label on both `Contact` initializers is
  renamed to `relayURL:` as well. Because `Contact` is `Codable`, its JSON key changes from
  `relayUrl` to `relayURL`; clients that persist encoded contacts need to migrate stored data.
- **Breaking**: the `relayUrl:` argument label is now `relayURL:` on
  `EventSigner.signRepost(of:relayURL:)`, `client.events.publishReply(to:content:relayURL:strategy:)`,
  and `client.events.publishRepost(of:relayURL:strategy:)`, completing the `relayURL` spelling across
  the package.
- **Breaking**: relay-targeted operations now throw instead of silently succeeding against zero
  relays. `RelayPool.publish`/`subscribe`/`count` — and the `NostrClient` publish, subscribe,
  fetch, and count flows built on them — throw the new `NostrError.noRelaysInPool` when the pool
  is empty and `NostrError.noMatchingRelays` when none of the targeted URLs are in the pool
  (partial matches still proceed). Previously publish returned an empty result, subscribe
  reported 0 relays, count returned `[:]`, and fetch stalled to its timeout before returning
  `[]`. The two cases are additive but a source break for code that switches over `NostrError`
  exhaustively; `connectAll()` on an empty pool still returns 0.
- **Breaking**: relay pool keys are normalized. `addRelay`, `removeRelay`, `relay(for:)`, and
  targeted publish/subscribe/count canonicalize URLs — lowercased scheme and host, root trailing
  slash stripped, default ports stripped — so any spelling of the same relay routes to the one
  connection, re-adding a relay under a different spelling returns the existing connection, and
  publish results are keyed by the canonical URL.
- **Breaking**: relay targeting is string-based. The `to:` parameter of `RelayPool.publish`,
  `RelayPool.count`, `RelayPool.subscribe`, and of `NostrClient.subscribe`, `events`, and `fetch`
  is now `[String]?` instead of `Set<URL>?`: nil (the default) broadcasts to the whole pool, an
  empty array throws `noMatchingRelays`, duplicates de-dupe by normalized key, and an invalid
  string throws the new `NostrError.invalidRelayURL` — a target must parse, use a `ws`/`wss`
  scheme, have a host, and carry no fragment or user/password.
- **Breaking**: the relay-management surface validates strictly and drops its labels.
  `RelayPool.addRelay(url:)`/`addRelay(urlString:)` collapse into `addRelay(_:config:)` overloads
  taking a `String` or a `URL` — both now throw `invalidRelayURL` for a non-WebSocket URL — and
  `removeRelay(url:)` becomes `removeRelay(_:)` with a validating `String` overload (removing an
  absent relay stays a no-op). `RelayConnection(urlString:)` and the invalid-URL path of
  `connect(to:)` now throw `invalidRelayURL` instead of `connectionFailed`, and
  `NostrClient.authenticate(relayURL:)` throws `noMatchingRelays` instead of a generic
  `relayError` when the relay is not in the pool.
- **Breaking**: NIP-65/NIP-17 relay-list parsing skips non-WebSocket URLs. Routing sets built from
  kind-10002/10050 tags (and the gossip resolvers on top of them) now drop entries with a
  non-`ws(s)` scheme, a missing host, or a fragment/userinfo instead of keeping them as routing
  keys, and the resolved sets always carry canonical URL spellings.
- **Breaking**: `RemoteSignerTransport` and `WalletConnectTransport` are replaced by a single
  `NostrCore.RelayTransport`. The two protocols were the same six requirements with nothing
  NIP-specific in either, and their default implementations were the same actor twice over. For a
  custom transport this is a one-line rename — the requirements are unchanged and both libraries
  re-export `NostrCore`, so no import changes either. The shared default `RelayConnectionTransport`
  moves to `NostrCore` with them, and now throws `NostrError.notConnected` instead of
  `RemoteSignerError.notConnected` / `WalletConnectError.notConnected` when an operation reaches no
  relay; both of those cases remain, still thrown for the session-level failures they already
  covered.

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

[Unreleased]: https://github.com/yysskk/swift-nostr/compare/0.8.0...HEAD
[0.8.0]: https://github.com/yysskk/swift-nostr/compare/0.7.0...0.8.0
[0.7.0]: https://github.com/yysskk/swift-nostr/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/yysskk/swift-nostr/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/yysskk/swift-nostr/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/yysskk/swift-nostr/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/yysskk/swift-nostr/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/yysskk/swift-nostr/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/yysskk/swift-nostr/releases/tag/0.1.0
