import Foundation
import NostrCore
import Testing

@Suite("RelayMessage Tests")
struct RelayMessageTests {

    @Test("Parse EVENT message")
    func parseEventMessage() throws {
        let json =
            #"["EVENT","sub1",{"id":"abc123","pubkey":"def456","created_at":1234567890,"kind":1,"tags":[],"content":"Hello","sig":"sig123"}]"#

        let message = try RelayMessage.parse(json)

        if case .event(let subscriptionId, let event) = message {
            #expect(subscriptionId == "sub1")
            #expect(event.id == "abc123")
            #expect(event.pubkey == "def456")
            #expect(event.content == "Hello")
        } else {
            Issue.record("Expected EVENT message")
        }
    }

    @Test("Parse EOSE message")
    func parseEoseMessage() throws {
        let json = #"["EOSE","sub1"]"#

        let message = try RelayMessage.parse(json)

        if case .endOfStoredEvents(let subscriptionId) = message {
            #expect(subscriptionId == "sub1")
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
        let json = #"["OK","eventid123",true,""]"#

        let message = try RelayMessage.parse(json)

        if case .ok(let eventId, let accepted, let okMessage) = message {
            #expect(eventId == "eventid123")
            #expect(accepted == true)
            #expect(okMessage == "")
        } else {
            Issue.record("Expected OK message")
        }
    }

    @Test("Parse OK message - rejected")
    func parseOkMessageRejected() throws {
        let json = #"["OK","eventid123",false,"duplicate: already have this event"]"#

        let message = try RelayMessage.parse(json)

        if case .ok(let eventId, let accepted, let okMessage) = message {
            #expect(eventId == "eventid123")
            #expect(accepted == false)
            #expect(okMessage == "duplicate: already have this event")
        } else {
            Issue.record("Expected OK message")
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

        if case .closed(let subscriptionId, let closedMessage) = message {
            #expect(subscriptionId == "sub1")
            #expect(closedMessage == "subscription closed by relay")
        } else {
            Issue.record("Expected CLOSED message")
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
            id: "id123",
            pubkey: "pubkey123",
            createdAt: 1_234_567_890,
            kind: 1,
            tags: [],
            content: "Hello",
            sig: "sig123"
        )

        let message = ClientMessage.event(event)
        let serialized = try message.serialize()

        #expect(serialized.contains("EVENT"))
        #expect(serialized.contains("id123"))
        #expect(serialized.contains("Hello"))
    }

    @Test("Serialize REQ message")
    func serializeReqMessage() throws {
        let filter = Filter(kinds: [1], limit: 10)
        let message = ClientMessage.request(subscriptionId: "sub1", filters: [filter])
        let serialized = try message.serialize()

        #expect(serialized.contains("REQ"))
        #expect(serialized.contains("sub1"))
        #expect(serialized.contains("kinds"))
    }

    @Test("Serialize CLOSE message")
    func serializeCloseMessage() throws {
        let message = ClientMessage.close(subscriptionId: "sub1")
        let serialized = try message.serialize()

        #expect(serialized == #"["CLOSE","sub1"]"#)
    }
}
