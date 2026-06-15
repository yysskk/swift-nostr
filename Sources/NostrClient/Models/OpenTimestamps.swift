import Foundation
import NostrCore

/// OpenTimestamps attestation support (NIP-03)
/// https://github.com/nostr-protocol/nips/blob/master/03.md
public struct OpenTimestamps: Sendable, Hashable {
    /// The base64-encoded OTS file data
    public let otsData: String

    /// Creates an OpenTimestamps attestation from base64-encoded OTS data
    public init(base64EncodedOTS: String) {
        self.otsData = base64EncodedOTS
    }

    /// Creates an OpenTimestamps attestation from raw OTS file data
    public init(otsFileData: Data) {
        self.otsData = otsFileData.base64EncodedString()
    }

    /// Returns the raw OTS file data
    public var rawData: Data? {
        Data(base64Encoded: otsData)
    }

    /// Creates a tag for embedding in an event
    public func toTag() -> [String] {
        ["ots", otsData]
    }
}

// MARK: - Event Extension for OpenTimestamps
extension Event {
    /// Returns the OpenTimestamps attestation if present
    public var openTimestamps: OpenTimestamps? {
        guard let otsTag = tags.first(where: { $0.first == "ots" }),
            otsTag.count >= 2
        else {
            return nil
        }
        return OpenTimestamps(base64EncodedOTS: otsTag[1])
    }

    /// Returns true if this event has an OpenTimestamps attestation
    public var hasOpenTimestampsAttestation: Bool {
        openTimestamps != nil
    }
}

// MARK: - UnsignedEvent Extension for OpenTimestamps
extension UnsignedEvent {
    /// Creates a new unsigned event with an OpenTimestamps tag added
    public func withOpenTimestamps(_ ots: OpenTimestamps) -> UnsignedEvent {
        var newTags = tags
        // Remove existing ots tag if present
        newTags.removeAll { $0.first == "ots" }
        newTags.append(ots.toTag())

        return UnsignedEvent(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            rawTags: newTags,
            content: content
        )
    }
}

// MARK: - EventSigner Extension for OpenTimestamps
extension EventSigner {
    /// Signs an event and attaches an OpenTimestamps attestation
    public func sign(_ unsignedEvent: UnsignedEvent, withOTS ots: OpenTimestamps) throws -> Event {
        let eventWithOTS = unsignedEvent.withOpenTimestamps(ots)
        return try sign(eventWithOTS)
    }
}
