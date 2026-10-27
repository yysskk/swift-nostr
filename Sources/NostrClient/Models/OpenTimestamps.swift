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

    /// The `ots` tag for embedding in an event: `["ots", base64 data]`.
    public var tag: Tag {
        Tag(name: "ots", values: [otsData])
    }
}

// MARK: - Event Extension for OpenTimestamps
extension Event {
    /// Returns the OpenTimestamps attestation if present
    public var openTimestamps: OpenTimestamps? {
        guard let otsData = firstTagValue(named: "ots") else {
            return nil
        }
        return OpenTimestamps(base64EncodedOTS: otsData)
    }

    /// Returns true if this event has an OpenTimestamps attestation
    public var hasOpenTimestampsAttestation: Bool {
        openTimestamps != nil
    }
}

// MARK: - EventTemplate Extension for OpenTimestamps
extension EventTemplate {
    /// The OpenTimestamps attestation carried by the template's `ots` tag, if any.
    ///
    /// Setting an attestation replaces any existing `ots` tag with one at the end of ``tags``;
    /// setting nil removes it:
    ///
    /// ```swift
    /// var note = EventTemplate.textNote("timestamped")
    /// note.openTimestamps = OpenTimestamps(otsFileData: otsFile)
    /// let event = try signer.sign(note)
    /// ```
    public var openTimestamps: OpenTimestamps? {
        get {
            tags.first { $0.name == "ots" }?.primaryValue.map(OpenTimestamps.init(base64EncodedOTS:))
        }
        set {
            tags.removeAll { $0.name == "ots" }
            if let newValue {
                tags.append(newValue.tag)
            }
        }
    }
}
