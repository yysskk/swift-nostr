import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

/// A command outside the built-in set, defined the way an application would define one.
private struct SignMessageRequest: WalletConnectRequest {
    typealias Response = SignMessageResult

    static let method = WalletConnectMethod(rawValue: "sign_message")

    let message: String
}

private struct SignMessageResult: Decodable, Sendable, Equatable {
    let message: String
    let signature: String
}

@Suite("WalletConnection send(_:) Tests")
struct WalletConnectSendTests {
    private func makeConnection(timeout: Duration = .seconds(2)) throws -> (
        connection: WalletConnection, transport: FakeWalletConnectTransport, client: KeyPair, wallet: KeyPair
    ) {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client),
            transport: transport,
            config: .init(requestTimeout: timeout, preferredEncryption: .nip44))
        return (connection, transport, client, wallet)
    }

    @Test("a custom request is sent under its method with itself as params, and its response decoded")
    func customRequestRoundTrip() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let signing = Task { try await connection.send(SignMessageRequest(message: "hello")) }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        #expect(request.kind == .walletConnectRequest)
        let body = try NWCFixtures.decryptRequest(request, client: client, wallet: wallet)
        let wire = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        #expect(wire == .object(["method": .string("sign_message"), "params": .object(["message": .string("hello")])]))

        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"sign_message","result":{"message":"hello","signature":"abcd"}}"#,
                requestID: request.id, client: client, wallet: wallet))

        #expect(try await signing.value == SignMessageResult(message: "hello", signature: "abcd"))
    }

    @Test("a wallet error answering a custom request is thrown as walletError")
    func customRequestWalletError() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let signing = Task { try await connection.send(SignMessageRequest(message: "hello")) }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"sign_message","error":{"code":"NOT_IMPLEMENTED","message":"no"}}"#,
                requestID: request.id, client: client, wallet: wallet))

        await #expect(throws: WalletConnectError.walletError(code: .notImplemented, message: "no")) {
            _ = try await signing.value
        }
    }

    @Test("a response naming another method is rejected with the request's method")
    func customRequestMismatchedResultType() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let signing = Task { try await connection.send(SignMessageRequest(message: "hello")) }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"get_balance","result":{"balance":1}}"#,
                requestID: request.id, client: client, wallet: wallet))

        await #expect(
            throws: WalletConnectError.unexpectedResultType(
                expected: WalletConnectMethod(rawValue: "sign_message"), received: .getBalance)
        ) {
            _ = try await signing.value
        }
    }

    @Test("a built-in request sent directly decodes its typed response")
    func builtInRequestThroughSend() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        let balance = Task { try await connection.send(GetBalanceRequest()) }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        let body = try NWCFixtures.decryptRequest(request, client: client, wallet: wallet)
        let wire = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        #expect(wire == .object(["method": .string("get_balance"), "params": .object([:])]))

        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"get_balance","result":{"balance":21000}}"#,
                requestID: request.id, client: client, wallet: wallet))

        #expect(try await balance.value == GetBalanceResult(balance: 21000))
    }
}
