# ``NostrWalletConnect``

Control a remote Lightning wallet over Nostr with NIP-47 Nostr Wallet Connect.

## Overview

NostrWalletConnect is a Swift implementation of [NIP-47 Nostr Wallet
Connect](https://github.com/nostr-protocol/nips/blob/master/47.md): a protocol that lets an
application drive a remote Lightning wallet over Nostr relays. It builds on `NostrCore` — reusing its
event, signing, encryption, and relay primitives — which it re-exports.

The headline use case is **completing a zap payment**. `NostrCore` can sign a zap request and fetch
a BOLT-11 invoice from a recipient's LNURL endpoint, but it cannot pay that invoice. A wallet
connection closes the gap: it asks a remote wallet to pay the invoice and return the payment
preimage.

- Actor-based ``WalletConnection`` with full `Sendable` compliance.
- The complete NIP-47 command set: pay, multi-pay, keysend, invoices, balance, info, and history.
- NIP-44 (preferred) and NIP-04 (legacy) payload encryption, negotiated from the wallet's info event.
- A wallet notification stream and a one-call end-to-end zap payment.
- Relay I/O behind `NostrCore`'s `RelayTransport` seam: the default `RelayConnectionTransport`
  drives the URI's relays, and a custom transport — or the default one on an injected
  `WebSocketSessionFactory` — takes its place for another relay stack, a platform-native socket, or
  a test without a live relay (see <doc:AdvancedUsage>).

```swift
import NostrWalletConnect

// Connect with the wallet's nostr+walletconnect:// string.
let uri = try WalletConnectURI(string: "nostr+walletconnect://...")
let connection = WalletConnection(uri: uri)

// Pay any invoice and get the preimage back.
let payment = try await connection.payInvoice("lnbc...")
print(payment.preimage)
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AdvancedUsage>
- ``WalletConnection``
- ``WalletConnectURI``

### Commands and Parameters

- ``WalletConnectMethod``
- ``PayInvoiceParams``
- ``MultiPayInvoiceParams``
- ``PayKeysendParams``
- ``MultiPayKeysendParams``
- ``MakeInvoiceParams``
- ``LookupInvoiceParams``
- ``ListTransactionsParams``
- ``EmptyParams``
- ``TLVRecord``
- ``TransactionType``

### Results

- ``PayInvoiceResult``
- ``PayKeysendResult``
- ``GetBalanceResult``
- ``GetInfoResult``
- ``ListTransactionsResult``
- ``MakeInvoiceResult``
- ``LookupInvoiceResult``
- ``MultiPayInvoiceItemResult``
- ``MultiPayKeysendItemResult``

### Transactions and Notifications

- ``WalletConnectTransaction``
- ``WalletConnectNotification``

### Wallet Info and Encryption

- ``WalletInfo``
- ``WalletConnectEncryption``

### Lightning Zaps (NIP-57)

- ``WalletConnection/payZap(lnurlPay:amountMillisats:zapRequest:lnurl:urlSession:)``
- ``ZapResult``

### Supporting Types

- ``JSONValue``

### Errors

- ``WalletConnectError``
- ``WalletConnectErrorCode``
