import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("Value Hashable Tests")
struct ValueHashableTests {
    private static func event(_ label: String) -> Event {
        Event(
            id: .fixture(label),
            publicKey: .fixture("author"),
            createdAt: 1_700_000_000,
            kind: .textNote,
            tags: [],
            content: label,
            signature: .fixture())
    }

    private static func unsignedEvent(_ content: String) -> UnsignedEvent {
        UnsignedEvent(publicKey: .fixture("author"), createdAt: 1_700_000_000, kind: .textNote, content: content)
    }

    private static let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
    private static let otherWords = Array(repeating: "abandon", count: 11) + ["about"]

    static let samples: [HashableSample] = [
        HashableSample("UnsignedEvent", unsignedEvent("a"), unsignedEvent("a"), unsignedEvent("b")),
        HashableSample(
            "ClientMessage", ClientMessage.event(event("a")), ClientMessage.event(event("a")),
            ClientMessage.auth(event("a"))),
        HashableSample(
            "RelayMessage",
            RelayMessage.ok(eventID: .fixture("a"), accepted: false, message: "pow: 20"),
            RelayMessage.ok(eventID: .fixture("a"), accepted: false, message: "pow: 20"),
            RelayMessage.ok(eventID: .fixture("a"), accepted: false, message: "pow: 30")),
        HashableSample(
            "NIP44Payload", NIP44Payload(base64: "AgAB"), NIP44Payload(base64: "AgAB"), NIP44Payload(base64: "AgAC")),
        HashableSample(
            "RelayConnectionState", RelayConnectionState.failed(.init(operation: .send, reason: "a")),
            RelayConnectionState.failed(.init(operation: .send, reason: "a")),
            RelayConnectionState.failed(.init(operation: .receive, reason: "a"))),
        HashableSample(
            "WebSocketMessage", WebSocketMessage.string("a"), WebSocketMessage.string("a"),
            WebSocketMessage.data(Data("a".utf8))),
        HashableSample(
            "RelayConnectionConfig", RelayConnectionConfig(), RelayConnectionConfig(),
            RelayConnectionConfig(publishAckTimeout: .seconds(5))),
        HashableSample(
            "RelayConnection.Error",
            RelayConnection.Error.authenticationRejected(RelayRejection(status: "restricted: no")),
            RelayConnection.Error.authenticationRejected(RelayRejection(status: "restricted: no")),
            RelayConnection.Error.authenticationRejected(RelayRejection(status: "restricted: never"))),
        HashableSample(
            "Mnemonic", try! Mnemonic(phrase: phrase), try! Mnemonic(phrase: phrase), try! Mnemonic(words: otherWords)),
    ]

    @Test("equal values are equal, hash alike, and collapse in a Set", arguments: samples)
    func hashable(sample: HashableSample) {
        #expect(sample.equalValuesAreEqual)
        #expect(sample.equalValuesHashAlike)
        #expect(sample.differentValueIsUnequal)
        #expect(sample.setCount == 2)
    }

    @Test("mnemonics compare by phrase, including across initializers")
    func mnemonicEqualityIsByValue() throws {
        let phrase = Self.phrase
        let fromPhrase = try Mnemonic(phrase: phrase)
        let fromWords = try Mnemonic(words: phrase.split(separator: " ").map(String.init))
        let generated = Mnemonic.generate(wordCount: .twentyFour)

        #expect(fromPhrase == fromWords)
        #expect(Set([fromPhrase, fromWords]).count == 1)
        #expect(fromPhrase != generated)
        #expect(try Mnemonic(phrase: generated.phrase) == generated)
    }

    @Test("a mnemonic's description, debug description, and dump never contain its words")
    func mnemonicIsRedacted() throws {
        let mnemonic = try Mnemonic(phrase: Self.phrase)
        var dumped = ""
        dump(mnemonic, to: &dumped)

        #expect(mnemonic.description == "Mnemonic(<redacted>)")
        #expect(mnemonic.debugDescription == "Mnemonic(<redacted>)")
        #expect(String(describing: mnemonic) == "Mnemonic(<redacted>)")
        for output in [mnemonic.description, mnemonic.debugDescription, String(reflecting: mnemonic), dumped] {
            for word in mnemonic.words {
                #expect(!output.contains(word))
            }
        }
    }
}
