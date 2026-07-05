import Testing

@testable import NostrConnect

@Suite("RemoteSigner Method Tests")
struct RemoteSignerMethodTests {
    @Test("every case maps to its expected wire token")
    func wireTokens() {
        #expect(RemoteSignerMethod.connect.rawValue == "connect")
        #expect(RemoteSignerMethod.signEvent.rawValue == "sign_event")
        #expect(RemoteSignerMethod.ping.rawValue == "ping")
        #expect(RemoteSignerMethod.getPublicKey.rawValue == "get_public_key")
        #expect(RemoteSignerMethod.nip04Encrypt.rawValue == "nip04_encrypt")
        #expect(RemoteSignerMethod.nip04Decrypt.rawValue == "nip04_decrypt")
        #expect(RemoteSignerMethod.nip44Encrypt.rawValue == "nip44_encrypt")
        #expect(RemoteSignerMethod.nip44Decrypt.rawValue == "nip44_decrypt")
        #expect(RemoteSignerMethod.switchRelays.rawValue == "switch_relays")
        #expect(RemoteSignerMethod.logout.rawValue == "logout")
    }

    @Test("allCases covers exactly the ten defined methods")
    func allCasesCount() {
        #expect(RemoteSignerMethod.allCases.count == 10)
    }
}
