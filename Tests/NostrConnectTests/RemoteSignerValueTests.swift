import Foundation
import NostrConnect
import NostrTestSupport
import Testing

@Suite("RemoteSigner Value Tests")
struct RemoteSignerValueTests {
    @Test("an auth challenge built by an app carries the fields it was given")
    func authChallengeInit() throws {
        let url = try #require(URL(string: "https://signer.example.com/approve?id=42"))
        let challenge = RemoteSignerAuthChallenge(url: url, method: .signEvent, requestID: "42")

        #expect(challenge.url == url)
        #expect(challenge.method == .signEvent)
        #expect(challenge.requestID == "42")
    }

    @Test("equal configs are equal, hash alike, and collapse in a Set")
    func configHashable() {
        let sample = HashableSample(
            "RemoteSigner.Config", RemoteSigner.Config(), RemoteSigner.Config(),
            RemoteSigner.Config(authChallengeTimeout: .seconds(60)))

        #expect(sample.equalValuesAreEqual)
        #expect(sample.equalValuesHashAlike)
        #expect(sample.differentValueIsUnequal)
        #expect(sample.setCount == 2)
    }
}
