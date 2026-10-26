import Foundation

/// Messages sent from the client to a relay (NIP-01)
public enum ClientMessage: Sendable {
    /// Used to publish events
    case event(Event)

    /// Used to request events and subscribe
    case request(subscriptionID: String, filters: [Filter])

    /// Used to stop a subscription
    case close(subscriptionID: String)

    /// Used for authentication (NIP-42)
    case auth(Event)

    /// Used to request the number of events matching the filters (NIP-45).
    /// https://github.com/nostr-protocol/nips/blob/master/45.md
    case count(subscriptionID: String, filters: [Filter])

    /// Serializes the message to JSON array format
    /// - Throws: The error `JSONEncoder` or `JSONSerialization` throws for an event or filter that
    ///   does not encode.
    public func serialize() throws -> String {
        let array: [Any]

        switch self {
        case .event(let event):
            let eventDict = try event.jsonObject()
            array = ["EVENT", eventDict]

        case .request(let subscriptionID, let filters):
            var arr: [Any] = ["REQ", subscriptionID]
            for filter in filters {
                let filterDict = try filter.jsonObject()
                arr.append(filterDict)
            }
            array = arr

        case .close(let subscriptionID):
            array = ["CLOSE", subscriptionID]

        case .auth(let event):
            let eventDict = try event.jsonObject()
            array = ["AUTH", eventDict]

        case .count(let subscriptionID, let filters):
            var arr: [Any] = ["COUNT", subscriptionID]
            for filter in filters {
                let filterDict = try filter.jsonObject()
                arr.append(filterDict)
            }
            array = arr
        }

        // `JSONSerialization` always writes UTF-8.
        let data = try JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Messages received from a relay (NIP-01)
public enum RelayMessage: Sendable {
    /// Event sent by the relay
    case event(subscriptionID: String, event: Event)

    /// End of stored events notice
    case endOfStoredEvents(subscriptionID: String)

    /// Notice message from the relay
    case notice(message: String)

    /// OK response for an event (NIP-01): whether the relay accepted the event with id
    /// `eventID`, and its status message.
    case ok(eventID: EventID, accepted: Bool, message: String)

    /// Authentication challenge (NIP-42)
    case auth(challenge: String)

    /// Closed subscription notice
    case closed(subscriptionID: String, message: String)

    /// Count of events matching the requested filters (NIP-45).
    /// https://github.com/nostr-protocol/nips/blob/master/45.md
    case count(subscriptionID: String, count: Int, approximate: Bool?)

    /// Unknown message type
    case unknown(type: String, rawData: String)

    /// Parses a raw JSON message from a relay.
    ///
    /// - Throws: ``RelayMessage/Error/malformed`` if the frame is not a JSON array or lacks the
    ///   fields its type requires — including an `OK` whose event id is not canonical 64-digit
    ///   lowercase hex, which cannot answer any event this client sent, and an `EVENT` carrying a
    ///   malformed event.
    public static func parse(_ text: String) throws(RelayMessage.Error) -> RelayMessage {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let array = object as? [Any],
            let type = array.first as? String
        else {
            throw .malformed
        }

        switch type {
        case "EVENT":
            guard array.count >= 3,
                let subscriptionID = array[1] as? String,
                let eventDict = array[2] as? [String: Any]
            else {
                throw .malformed
            }
            guard let event = try? Event(jsonObject: eventDict) else {
                throw .malformed
            }
            return .event(subscriptionID: subscriptionID, event: event)

        case "EOSE":
            guard array.count >= 2,
                let subscriptionID = array[1] as? String
            else {
                throw .malformed
            }
            return .endOfStoredEvents(subscriptionID: subscriptionID)

        case "NOTICE":
            guard array.count >= 2,
                let message = array[1] as? String
            else {
                throw .malformed
            }
            return .notice(message: message)

        case "OK":
            guard array.count >= 4,
                let eventID = (array[1] as? String).flatMap(EventID.init),
                let accepted = array[2] as? Bool,
                let message = array[3] as? String
            else {
                throw .malformed
            }
            return .ok(eventID: eventID, accepted: accepted, message: message)

        case "AUTH":
            guard array.count >= 2,
                let challenge = array[1] as? String
            else {
                throw .malformed
            }
            return .auth(challenge: challenge)

        case "CLOSED":
            guard array.count >= 3,
                let subscriptionID = array[1] as? String,
                let message = array[2] as? String
            else {
                throw .malformed
            }
            return .closed(subscriptionID: subscriptionID, message: message)

        case "COUNT":
            // The payload carries `count` and an optional `approximate` flag; any
            // other keys (e.g. the NIP-45 `hll` HyperLogLog value) are ignored.
            guard array.count >= 3,
                let subscriptionID = array[1] as? String,
                let payload = array[2] as? [String: Any],
                let count = payload["count"] as? Int
            else {
                throw .malformed
            }
            let approximate = payload["approximate"] as? Bool
            return .count(subscriptionID: subscriptionID, count: count, approximate: approximate)

        default:
            return .unknown(type: type, rawData: text)
        }
    }

    /// Why a relay frame could not be parsed as a ``RelayMessage``.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The frame is not a JSON array, or lacks the elements its message type requires, or
        /// carries them with the wrong types — including an `EVENT` whose event does not decode.
        case malformed

        public var errorDescription: String? {
            switch self {
            case .malformed:
                return "The relay message is malformed"
            }
        }
    }
}

// MARK: - Codable Helpers
extension Encodable {
    /// Encodes the value and reads it back as a JSON object for `JSONSerialization`.
    fileprivate func jsonObject() throws -> [String: Any] {
        // No key strategy: every declared key already carries its NIP-01 wire spelling
        // (`created_at`, `#e`, `#p`), so converting would be a no-op for them — while corrupting
        // the dynamic keys `Filter` emits for generic tag queries. Converting to snake case turns
        // the uppercase tags NIP-22 uses for root scope (`#A`, `#E`, `#I`, `#K`, `#P`) into `#_a`
        // and friends, which a relay does not recognize: it drops the unknown key and answers the
        // rest of the filter, silently returning more than was asked for.
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        // Only `Event` and `Filter` come through here, and both encode as keyed containers.
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("\(Self.self) did not encode as a JSON object")
        }
        return dict
    }
}

extension Event {
    /// Decodes an event from a JSON object produced by `JSONSerialization`.
    fileprivate init(jsonObject: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        let decoder = JSONDecoder()
        self = try decoder.decode(Event.self, from: data)
    }
}
