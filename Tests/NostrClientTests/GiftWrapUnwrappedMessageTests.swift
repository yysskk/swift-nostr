import NostrClient
import NostrCore
import Testing

// Imports `NostrClient` without `@testable` so the test fails if the initializer stops being public.
@Suite("GiftWrap.UnwrappedMessage Tests")
struct GiftWrapUnwrappedMessageTests {

    @Test("an app can create a message from a known sender and rumor")
    func publicInitializerKeepsItsValues() {
        let keyPair = KeyPair()
        let event = EventSigner(keyPair: keyPair).sign(.textNote("hello"))

        let message = GiftWrap.UnwrappedMessage(senderPublicKey: keyPair.publicKey, event: event)

        #expect(message.senderPublicKey == keyPair.publicKey)
        #expect(message.event == event)
    }
}
