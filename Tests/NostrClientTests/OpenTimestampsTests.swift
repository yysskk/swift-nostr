import Foundation
import NostrCore
import NostrTestSupport
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

    @Test("OpenTimestamps tag")
    func tag() {
        let base64Data = "SGVsbG8gT1RT"
        let ots = OpenTimestamps(base64EncodedOTS: base64Data)
        let tag = ots.tag

        #expect(tag.rawArray == ["ots", base64Data])
    }

    @Test("A template's attestation is signed into the event and read back")
    func eventWithOTS() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let otsData = "dGVzdCBvdHMgZGF0YQ=="

        var template = EventTemplate.textNote("Test with OTS", tags: [.hashtag("test")])
        template.openTimestamps = OpenTimestamps(base64EncodedOTS: otsData)
        let event = signer.sign(template)

        #expect(event.tags.map(\.rawArray) == [["t", "test"], ["ots", otsData]])
        #expect(event.hasOpenTimestampsAttestation)
        #expect(event.openTimestamps?.otsData == otsData)
        #expect(try event.verify())
    }

    @Test("Event without OpenTimestamps attestation")
    func eventWithoutOTS() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = signer.sign(.textNote("No OTS here"))

        #expect(!event.hasOpenTimestampsAttestation)
        #expect(event.openTimestamps == nil)
    }

    @Test("Setting openTimestamps appends an ots tag and keeps the rest of the template")
    func templateSetsOTS() {
        let ots = OpenTimestamps(base64EncodedOTS: "dGVzdCBvdHM=")

        var template = EventTemplate.textNote("Test content", tags: [.publicKey(.fixture("someone"))])
        #expect(template.openTimestamps == nil)
        template.openTimestamps = ots

        #expect(template.openTimestamps == ots)
        #expect(template.tags == [.publicKey(.fixture("someone")), ots.tag])
        #expect(template.content == "Test content")
        #expect(template.kind == .textNote)
    }

    @Test("Setting openTimestamps replaces an existing ots tag")
    func replaceExistingOTS() {
        let newOTS = OpenTimestamps(base64EncodedOTS: "bmV3")

        var template = EventTemplate(
            kind: .textNote,
            tags: [Tag(name: "ots", values: ["b2xk"]), .hashtag("test")],
            content: "Test content"
        )
        #expect(template.openTimestamps?.otsData == "b2xk")
        template.openTimestamps = newOTS

        #expect(template.tags == [.hashtag("test"), Tag(name: "ots", values: ["bmV3"])])
        #expect(template.openTimestamps == newOTS)
    }

    @Test("Setting openTimestamps to nil removes the ots tag")
    func removeOTS() {
        var template = EventTemplate(
            kind: .textNote,
            tags: [.hashtag("test"), Tag(name: "ots", values: ["b2xk"])],
            content: "Test content"
        )
        template.openTimestamps = nil

        #expect(template.tags == [.hashtag("test")])
        #expect(template.openTimestamps == nil)
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
