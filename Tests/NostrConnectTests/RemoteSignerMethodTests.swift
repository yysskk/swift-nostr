import Foundation
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Method Tests")
struct RemoteSignerMethodTests {
    @Test("every constant maps to its expected wire token")
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

    @Test("an unknown method is preserved and equal to one built from the same token")
    func unknownMethodPreserved() {
        let method = RemoteSignerMethod(rawValue: "get_session_info")
        #expect(method.rawValue == "get_session_info")
        #expect(method.description == "get_session_info")
        #expect(method == RemoteSignerMethod(rawValue: "get_session_info"))
        #expect(method != .getPublicKey)
    }

    @Test("encodes as a bare JSON string")
    func encodesAsBareString() throws {
        let data = try JSONEncoder().encode([RemoteSignerMethod.signEvent, RemoteSignerMethod(rawValue: "custom")])
        #expect(String(decoding: data, as: UTF8.self) == #"["sign_event","custom"]"#)
    }

    @Test("decodes known and unknown tokens from a bare JSON string")
    func decodesBareString() throws {
        let decoded = try JSONDecoder().decode(
            [RemoteSignerMethod].self, from: Data(#"["nip44_encrypt","get_session_info"]"#.utf8))
        #expect(decoded == [.nip44Encrypt, RemoteSignerMethod(rawValue: "get_session_info")])
    }
}
