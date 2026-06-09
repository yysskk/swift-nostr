import Foundation
import Testing

@testable import NostrClient

@Suite("OpenTimestamps Tests (NIP-03)")
struct OpenTimestampsTests {

    @Test("Create OpenTimestamps from base64 string")
    func createFromBase64() {
        let base64Data = "SGVsbG8gT1RT"
        let ots = OpenTimestamps(base64EncodedOTS: base64Data)

        #expect(ots.otsData == base64Data)
    }

    @Test("Create OpenTimestamps from raw data")
    func createFromRawData() {
        let rawData = "Hello OTS".data(using: .utf8)!
        let ots = OpenTimestamps(otsFileData: rawData)

        #expect(ots.otsData == rawData.base64EncodedString())
        #expect(ots.rawData == rawData)
    }

    @Test("OpenTimestamps to tag conversion")
    func toTag() {
        let base64Data = "SGVsbG8gT1RT"
        let ots = OpenTimestamps(base64EncodedOTS: base64Data)
        let tag = ots.toTag()

        #expect(tag == ["ots", base64Data])
    }

    @Test("Event with OpenTimestamps attestation")
    func eventWithOTS() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let otsData = "dGVzdCBvdHMgZGF0YQ=="
        let ots = OpenTimestamps(base64EncodedOTS: otsData)

        let unsigned = UnsignedEvent(
            pubkey: keyPair.publicKeyHex,
            kind: .textNote,
            tags: [["t", "test"]],
            content: "Test with OTS"
        )

        let event = try signer.sign(unsigned, withOTS: ots)

        #expect(event.hasOpenTimestampsAttestation)
        #expect(event.openTimestamps?.otsData == otsData)
        #expect(event.tags.contains { $0 == ["ots", otsData] })
        #expect(event.tags.contains { $0 == ["t", "test"] })
    }

    @Test("Event without OpenTimestamps attestation")
    func eventWithoutOTS() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signTextNote(content: "No OTS here")

        #expect(!event.hasOpenTimestampsAttestation)
        #expect(event.openTimestamps == nil)
    }

    @Test("UnsignedEvent withOpenTimestamps")
    func unsignedEventWithOTS() throws {
        let keyPair = try KeyPair()
        let otsData = "dGVzdCBvdHM="
        let ots = OpenTimestamps(base64EncodedOTS: otsData)

        let unsigned = UnsignedEvent(
            pubkey: keyPair.publicKeyHex,
            kind: .textNote,
            tags: [["p", "somepubkey"]],
            content: "Test content"
        )

        let withOTS = unsigned.withOpenTimestamps(ots)

        #expect(withOTS.tags.contains { $0 == ["ots", otsData] })
        #expect(withOTS.tags.contains { $0 == ["p", "somepubkey"] })
        #expect(withOTS.content == unsigned.content)
        #expect(withOTS.kind == unsigned.kind)
    }

    @Test("withOpenTimestamps replaces existing OTS tag")
    func replaceExistingOTS() throws {
        let keyPair = try KeyPair()
        let newOTS = OpenTimestamps(base64EncodedOTS: "bmV3")

        let unsigned = UnsignedEvent(
            pubkey: keyPair.publicKeyHex,
            kind: .textNote,
            tags: [["ots", "b2xk"], ["t", "test"]],
            content: "Test content"
        )

        let withNewOTS = unsigned.withOpenTimestamps(newOTS)

        let otsTags = withNewOTS.tags.filter { $0.first == "ots" }
        #expect(otsTags.count == 1)
        #expect(otsTags.first == ["ots", "bmV3"])
    }

    @Test("OpenTimestamps equality")
    func equality() {
        let ots1 = OpenTimestamps(base64EncodedOTS: "dGVzdA==")
        let ots2 = OpenTimestamps(base64EncodedOTS: "dGVzdA==")
        let ots3 = OpenTimestamps(base64EncodedOTS: "b3RoZXI=")

        #expect(ots1 == ots2)
        #expect(ots1 != ots3)
    }

    @Test("OpenTimestamps hashable")
    func hashable() {
        let ots1 = OpenTimestamps(base64EncodedOTS: "dGVzdA==")
        let ots2 = OpenTimestamps(base64EncodedOTS: "dGVzdA==")

        var set: Set<OpenTimestamps> = []
        set.insert(ots1)
        set.insert(ots2)

        #expect(set.count == 1)
    }
}
