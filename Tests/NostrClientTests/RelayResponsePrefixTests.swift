import Foundation
import Testing

@testable import NostrClient

@Suite("RelayResponsePrefix Tests")
struct RelayResponsePrefixTests {

    @Test(
        "Parse standardized prefixes from status strings",
        arguments: [
            ("duplicate: already have this event", RelayResponsePrefix.duplicate),
            ("pow: difficulty 25 is less than 30", .pow),
            ("blocked: you are banned from posting here", .blocked),
            ("rate-limited: slow down there chief", .rateLimited),
            ("invalid: event creation date is too far off from the current time", .invalid),
            ("restricted: not allowed to write for this pubkey", .restricted),
            ("mute: this pubkey is muted", .mute),
            ("error: could not connect to the database", .error),
            ("auth-required: we only accept events from registered users", .authRequired),
        ]
    )
    func parseStandardizedPrefix(message: String, expected: RelayResponsePrefix) {
        #expect(RelayResponsePrefix(message: message) == expected)
    }

    @Test("Unknown single-word prefix is preserved as-is")
    func parseUnknownPrefix() {
        let prefix = RelayResponsePrefix(message: "deleted: user requested deletion")
        #expect(prefix?.rawValue == "deleted")
    }

    @Test("Message without a colon has no prefix")
    func messageWithoutColon() {
        #expect(RelayResponsePrefix(message: "all good") == nil)
    }

    @Test("Empty message has no prefix")
    func emptyMessage() {
        #expect(RelayResponsePrefix(message: "") == nil)
    }

    @Test("Prose containing a colon mid-sentence is not a prefix")
    func proseWithColon() {
        #expect(RelayResponsePrefix(message: "something went wrong: try again") == nil)
    }

    @Test("Message starting with a colon has no prefix")
    func leadingColon() {
        #expect(RelayResponsePrefix(message: ": missing prefix") == nil)
    }

    @Test("Prefix with an empty human-readable part still parses")
    func emptyHumanReadablePart() {
        #expect(RelayResponsePrefix(message: "error:") == .error)
    }

    @Test("Matching is case-sensitive, per the lowercase wire format")
    func caseSensitivity() {
        #expect(RelayResponsePrefix(message: "DUPLICATE: already have it") != .duplicate)
    }

    @Test("Prefix is expressible by string literal")
    func stringLiteral() {
        let prefix: RelayResponsePrefix = "auth-required"
        #expect(prefix == .authRequired)
    }

    @Test("Description is the raw wire value")
    func description() {
        #expect(RelayResponsePrefix.rateLimited.description == "rate-limited")
    }
}

@Suite("RelayMessage Response Prefix Tests")
struct RelayMessageResponsePrefixTests {

    @Test("OK message exposes its machine-readable prefix")
    func okPrefix() throws {
        let message = try RelayMessage.parse(
            #"["OK","eventid123",false,"auth-required: we only accept events from registered users"]"#
        )
        #expect(message.responsePrefix == .authRequired)
    }

    @Test("CLOSED message exposes its machine-readable prefix")
    func closedPrefix() throws {
        let message = try RelayMessage.parse(
            #"["CLOSED","sub1","auth-required: we can't serve DMs to unauthenticated users"]"#
        )
        #expect(message.responsePrefix == .authRequired)
    }

    @Test("OK message without a prefix has none")
    func okWithoutPrefix() throws {
        let message = try RelayMessage.parse(#"["OK","eventid123",true,""]"#)
        #expect(message.responsePrefix == nil)
    }

    @Test("Messages that carry no status string have no prefix")
    func otherMessagesHaveNoPrefix() throws {
        let eose = try RelayMessage.parse(#"["EOSE","sub1"]"#)
        #expect(eose.responsePrefix == nil)

        let notice = try RelayMessage.parse(#"["NOTICE","restricted: this looks like a prefix but NOTICE has none"]"#)
        #expect(notice.responsePrefix == nil)
    }
}
