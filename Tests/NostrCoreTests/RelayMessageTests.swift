import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("RelayMessage Tests")
struct RelayMessageTests {

    @Test("Parse EVENT message")
    func parseEventMessage() throws {
        let json =
            #"["EVENT","sub1",{"id":"abababababababababababababababababababababababababababababababab","pubkey":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","created_at":1234567890,"kind":1,"tags":[],"content":"Hello","sig":"efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef"}]"#

        let message = try RelayMessage.parse(json)

        if case .event(let subscriptionID, let event) = message {
            #expect(subscriptionID == "sub1")
            #expect(event.id.hex == String(repeating: "ab", count: 32))
            #expect(event.publicKey.hex == String(repeating: "cd", count: 32))
            #expect(event.signature?.hex == String(repeating: "ef", count: 64))
            #expect(event.content == "Hello")
        } else {
            Issue.record("Expected EVENT message")
        }
    }

    @Test("an EVENT message carrying a malformed event fails to parse")
    func parseEventMessageWithMalformedEvent() {
        let json =
            #"["EVENT","sub1",{"id":"abc123","pubkey":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","created_at":1234567890,"kind":1,"tags":[],"content":"Hello","sig":"efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef"}]"#

        #expect(throws: DecodingError.self) {
            try RelayMessage.parse(json)
        }
    }

    @Test("Parse EOSE message")
    func parseEoseMessage() throws {
        let json = #"["EOSE","sub1"]"#

        let message = try RelayMessage.parse(json)

        if case .endOfStoredEvents(let subscriptionID) = message {
            #expect(subscriptionID == "sub1")
        } else {
            Issue.record("Expected EOSE message")
        }
    }

    @Test("Parse NOTICE message")
    func parseNoticeMessage() throws {
        let json = #"["NOTICE","Rate limit exceeded"]"#

        let message = try RelayMessage.parse(json)

        if case .notice(let noticeMessage) = message {
            #expect(noticeMessage == "Rate limit exceeded")
        } else {
            Issue.record("Expected NOTICE message")
        }
    }

    @Test("Parse OK message - accepted")
    func parseOkMessageAccepted() throws {
        let id = EventID.fixture("ok")
        let json = #"["OK","\#(id.hex)",true,""]"#

        let message = try RelayMessage.parse(json)

        if case .ok(let eventID, let accepted, let okMessage) = message {
            #expect(eventID == id)
            #expect(accepted == true)
            #expect(okMessage == "")
        } else {
            Issue.record("Expected OK message")
        }
    }

    @Test("Parse OK message - rejected")
    func parseOkMessageRejected() throws {
        let id = EventID.fixture("ok")
        let json = #"["OK","\#(id.hex)",false,"duplicate: already have this event"]"#

        let message = try RelayMessage.parse(json)

        if case .ok(let eventID, let accepted, let okMessage) = message {
            #expect(eventID == id)
            #expect(accepted == false)
            #expect(okMessage == "duplicate: already have this event")
        } else {
            Issue.record("Expected OK message")
        }
    }

    /// An OK can only answer an event this client sent, and those always carry a canonical id — so
    /// a frame whose id is anything else is malformed, like an EVENT carrying a malformed event.
    @Test(
        "Parse OK message - a malformed event id fails to parse",
        arguments: [
            "eventid123",
            "",
            String(repeating: "A", count: 64),
            String(repeating: "0", count: 63),
        ])
    func parseOkMessageWithMalformedID(id: String) {
        #expect(throws: NostrError.invalidMessageFormat) {
            try RelayMessage.parse(#"["OK","\#(id)",true,""]"#)
        }
    }

    @Test("Parse AUTH message")
    func parseAuthMessage() throws {
        let json = #"["AUTH","challenge123"]"#

        let message = try RelayMessage.parse(json)

        if case .auth(let challenge) = message {
            #expect(challenge == "challenge123")
        } else {
            Issue.record("Expected AUTH message")
        }
    }

    @Test("Parse CLOSED message")
    func parseClosedMessage() throws {
        let json = #"["CLOSED","sub1","subscription closed by relay"]"#

        let message = try RelayMessage.parse(json)

        if case .closed(let subscriptionID, let closedMessage) = message {
            #expect(subscriptionID == "sub1")
            #expect(closedMessage == "subscription closed by relay")
        } else {
            Issue.record("Expected CLOSED message")
        }
    }

    @Test("Parse COUNT message (NIP-45)")
    func parseCountMessage() throws {
        let json = #"["COUNT","sub1",{"count":238}]"#

        let message = try RelayMessage.parse(json)

        if case .count(let subscriptionID, let count, let approximate) = message {
            #expect(subscriptionID == "sub1")
            #expect(count == 238)
            #expect(approximate == nil)
        } else {
            Issue.record("Expected COUNT message")
        }
    }

    @Test("Parse COUNT message with approximate flag (NIP-45)")
    func parseCountMessageApproximate() throws {
        let json = #"["COUNT","sub1",{"count":93,"approximate":true}]"#

        let message = try RelayMessage.parse(json)

        if case .count(let subscriptionID, let count, let approximate) = message {
            #expect(subscriptionID == "sub1")
            #expect(count == 93)
            #expect(approximate == true)
        } else {
            Issue.record("Expected COUNT message")
        }
    }

    @Test("Malformed COUNT message throws invalidMessageFormat")
    func parseMalformedCountMessage() {
        // Missing the `count` key in the payload.
        #expect(throws: NostrError.invalidMessageFormat) {
            _ = try RelayMessage.parse(#"["COUNT","sub1",{"approximate":true}]"#)
        }
        // Payload is not a dictionary.
        #expect(throws: NostrError.invalidMessageFormat) {
            _ = try RelayMessage.parse(#"["COUNT","sub1",238]"#)
        }
        // Too short — no payload element.
        #expect(throws: NostrError.invalidMessageFormat) {
            _ = try RelayMessage.parse(#"["COUNT","sub1"]"#)
        }
    }

    @Test("Parse unknown message type")
    func parseUnknownMessage() throws {
        let json = #"["UNKNOWN","data1","data2"]"#

        let message = try RelayMessage.parse(json)

        if case .unknown(let type, _) = message {
            #expect(type == "UNKNOWN")
        } else {
            Issue.record("Expected unknown message")
        }
    }

    @Test("Invalid message format throws error")
    func invalidMessageFormat() {
        let json = "not json"
        #expect(throws: (any Error).self) {
            _ = try RelayMessage.parse(json)
        }
    }
}

@Suite("ClientMessage Tests")
struct ClientMessageTests {

    @Test("Serialize EVENT message")
    func serializeEventMessage() throws {
        let event = Event(
            id: EventID.fixture("id123"),
            publicKey: PublicKey.fixture("pubkey123"),
            createdAt: Timestamp(rawValue: 1_234_567_890),
            kind: 1,
            tags: [],
            content: "Hello",
            signature: nil
        )

        let message = ClientMessage.event(event)
        let serialized = try message.serialize()

        #expect(serialized.contains("EVENT"))
        #expect(serialized.contains(event.id.hex))
        #expect(serialized.contains("Hello"))
    }

    @Test("Serialize REQ message")
    func serializeReqMessage() throws {
        let filter = Filter(kinds: [1], limit: 10)
        let message = ClientMessage.request(subscriptionID: "sub1", filters: [filter])
        let serialized = try message.serialize()

        #expect(serialized.contains("REQ"))
        #expect(serialized.contains("sub1"))
        #expect(serialized.contains("kinds"))
    }

    @Test("Serialize REQ message with search filter")
    func serializeReqMessageWithSearch() throws {
        let filter = Filter.search("nostr", kinds: [.textNote], limit: 20)
        let message = ClientMessage.request(subscriptionID: "sub1", filters: [filter])
        let serialized = try message.serialize()

        #expect(serialized.contains("REQ"))
        #expect(serialized.contains("sub1"))
        #expect(serialized.contains(#""search":"nostr""#))
    }

    @Test("Serialize CLOSE message")
    func serializeCloseMessage() throws {
        let message = ClientMessage.close(subscriptionID: "sub1")
        let serialized = try message.serialize()

        #expect(serialized == #"["CLOSE","sub1"]"#)
    }

    @Test("Serialize COUNT message (NIP-45)")
    func serializeCountMessage() throws {
        let filter = Filter(kinds: [.textNote])
        let message = ClientMessage.count(subscriptionID: "sub1", filters: [filter])
        let serialized = try message.serialize()

        #expect(serialized.hasPrefix(#"["COUNT","sub1",{"#))
        #expect(serialized.contains("kinds"))
    }
}
