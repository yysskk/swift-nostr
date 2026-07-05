import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Permission Tests")
struct RemoteSignerPermissionTests {
    @Test("signEvent with a kind is scoped to that kind")
    func signEventWithKind() {
        #expect(RemoteSignerPermission.signEvent(kind: .textNote).rawValue == "sign_event:1")
    }

    @Test("signEvent without a kind is unscoped")
    func signEventWithoutKind() {
        #expect(RemoteSignerPermission.signEvent().rawValue == "sign_event")
    }

    @Test("static constants use their method wire tokens")
    func staticConstants() {
        #expect(RemoteSignerPermission.nip44Encrypt.rawValue == "nip44_encrypt")
        #expect(RemoteSignerPermission.nip44Decrypt.rawValue == "nip44_decrypt")
        #expect(RemoteSignerPermission.nip04Encrypt.rawValue == "nip04_encrypt")
        #expect(RemoteSignerPermission.nip04Decrypt.rawValue == "nip04_decrypt")
        #expect(RemoteSignerPermission.getPublicKey.rawValue == "get_public_key")
    }
}
