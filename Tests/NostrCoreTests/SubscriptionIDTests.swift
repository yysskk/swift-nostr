import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("SubscriptionID Tests")
struct SubscriptionIDTests {

    @Test("encodes and decodes as its bare string")
    func codableAsBareString() throws {
        let id: SubscriptionID = "sub1"
        let encoded = try JSONEncoder().encode(id)
        #expect(String(decoding: encoded, as: UTF8.self) == #""sub1""#)
        #expect(try JSONDecoder().decode(SubscriptionID.self, from: Data(#""sub1""#.utf8)) == id)
    }

    @Test("description is the raw value")
    func descriptionIsRawValue() {
        let id = SubscriptionID(rawValue: "nwc-responses")
        #expect(id.description == "nwc-responses")
        #expect("\(id)" == "nwc-responses")
    }

    @Test("generated ids are unique, non-empty, and within the NIP-01 limit of 64 characters")
    func randomIDsAreUniqueAndShort() {
        let ids = (0..<1000).map { _ in SubscriptionID.random() }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { !$0.rawValue.isEmpty && $0.rawValue.count <= 64 })
    }

    // MARK: - Wire format

    @Test("REQ, COUNT, and CLOSE carry the id as a bare string")
    func clientMessagesSerializeTheID() {
        let filter = Filter(kinds: [.textNote])
        #expect(
            ClientMessage.request(subscriptionID: "sub1", filters: [filter]).serialize()
                == #"["REQ","sub1",{"kinds":[1]}]"#)
        #expect(
            ClientMessage.count(subscriptionID: "sub1", filters: [filter]).serialize()
                == #"["COUNT","sub1",{"kinds":[1]}]"#)
        #expect(ClientMessage.close(subscriptionID: "sub1").serialize() == #"["CLOSE","sub1"]"#)
    }

    @Test("EVENT, EOSE, CLOSED, and COUNT parse the id from its bare string")
    func relayMessagesParseTheID() throws {
        let event = EventSigner(keyPair: KeyPair()).sign(.textNote("hello"))
        let eventJSON = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        let frames = [
            #"["EVENT","sub1","# + eventJSON + "]",
            #"["EOSE","sub1"]"#,
            #"["CLOSED","sub1","error: shutting down"]"#,
            #"["COUNT","sub1",{"count":3}]"#,
        ]
        for frame in frames {
            switch try RelayMessage(json: frame) {
            case .event(let id, _), .endOfStoredEvents(let id), .closed(let id, _), .count(let id, _):
                #expect(id == SubscriptionID(rawValue: "sub1"))
            default:
                Issue.record("\(frame) did not parse as a subscription message")
            }
        }
    }
}
