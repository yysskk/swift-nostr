import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

/// A NIP-47 response names the scheme it was encrypted with. Assuming the request's scheme instead
/// meant a wallet answering in NIP-04 could not be read at all — including the
/// `UNSUPPORTED_ENCRYPTION` error that explains the mismatch, which is exactly the message a user
/// needs to see.
@Suite("Wallet Response Scheme Tests")
struct ResponseSchemeTests {
    private func makeConnection(
        preferred: WalletConnectEncryption? = .nip44,
        timeout: TimeInterval = 2
    ) throws -> (
        connection: WalletConnection, transport: FakeWalletConnectTransport, client: KeyPair, wallet: KeyPair
    ) {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client),
            transport: transport,
            config: .init(requestTimeout: timeout, preferredEncryption: preferred))
        return (connection, transport, client, wallet)
    }

    /// The request went out as NIP-44 and the wallet answered in NIP-04, saying so. Decrypting with
    /// the request's scheme failed and surfaced as a generic decoding failure.
    @Test("a response encrypted with a different scheme is decrypted by its own tag")
    func responseSchemeOverridesRequestScheme() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"nip04ok"}}"#,
                requestID: request.id, client: client, wallet: wallet,
                scheme: .nip04, declaringEncryption: true))

        #expect(try await payment.value.preimage == "nip04ok")
    }

    /// The actionable case: a NIP-04-only wallet reporting the mismatch. That error could not be
    /// read, so the caller saw a decoding failure with nothing pointing at the cause.
    @Test("a wallet's unsupported-encryption error reaches the caller")
    func walletEncryptionErrorReachesCaller() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: """
                    {"result_type":"pay_invoice","error":{"code":"UNSUPPORTED_ENCRYPTION",\
                    "message":"this wallet only speaks nip04"}}
                    """,
                requestID: request.id, client: client, wallet: wallet,
                scheme: .nip04, declaringEncryption: true))

        await #expect(throws: WalletConnectError.self) {
            _ = try await payment.value
        }

        do {
            _ = try await payment.value
            Issue.record("expected the wallet's error")
        } catch let WalletConnectError.walletError(code, message) {
            #expect(code == .unsupportedEncryption)
            #expect(message == "this wallet only speaks nip04")
        }
    }

    /// A wallet that sends no `encryption` tag — the legacy shape — keeps working on the scheme the
    /// request used.
    @Test("a response with no encryption tag falls back to the request's scheme")
    func missingEncryptionTagFallsBack() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"legacy"}}"#,
                requestID: request.id, client: client, wallet: wallet, scheme: .nip44))

        #expect(try await payment.value.preimage == "legacy")
    }

    /// A scheme this package does not implement is named as such, rather than reported as a
    /// malformed payload.
    @Test("an unknown encryption scheme is reported")
    func unknownEncryptionSchemeIsReported() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.signed(
                kind: .walletConnectResponse,
                tags: [
                    ["e", request.id], ["p", client.publicKeyHex], ["encryption", "nip77_quantum"],
                ],
                content: try NWCFixtures.encrypt(
                    #"{"result_type":"pay_invoice","result":{"preimage":"x"}}"#,
                    to: client, from: wallet, scheme: .nip44),
                wallet: wallet))

        await #expect(throws: WalletConnectError.unsupportedEncryption("nip77_quantum")) {
            _ = try await payment.value
        }
    }

    // MARK: - Authenticity

    /// Guards the author check that was already in place, alongside the signature check added
    /// beside it — the two together are what make a response this wallet's answer.
    @Test("a response from another pubkey is ignored")
    func responseFromAnotherPubkeyIsIgnored() async throws {
        let (connection, transport, client, _) = try makeConnection(timeout: 0.3)
        let impostor = try KeyPair()

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"forged"}}"#,
                requestID: request.id, client: client, wallet: impostor))

        await #expect(throws: WalletConnectError.timedOut) {
            _ = try await payment.value
        }
    }

    /// The signature was never checked, so a response carrying the wallet's pubkey but signed by
    /// nobody satisfied the request outright.
    @Test("a response whose signature does not verify is ignored")
    func unsignedResponseIsIgnored() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 0.3)

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        let genuine = try NWCFixtures.response(
            resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"p"}}"#,
            requestID: request.id, client: client, wallet: wallet)
        // Same event, signature replaced with one that does not verify.
        await transport.emit(
            Event(
                id: genuine.id, pubkey: genuine.pubkey, createdAt: genuine.createdAt,
                kind: genuine.kind, tags: genuine.tags, content: genuine.content,
                sig: String(repeating: "ab", count: 64)))

        await #expect(throws: WalletConnectError.timedOut) {
            _ = try await payment.value
        }
    }
}
