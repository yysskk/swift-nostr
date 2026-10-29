import Foundation

/// Messages sent from the client to a relay (NIP-01)
public enum ClientMessage: Sendable, Hashable {
    /// Used to publish events
    case event(Event)

    /// Used to request events and subscribe
    case request(subscriptionID: SubscriptionID, filters: [Filter])

    /// Used to stop a subscription
    case close(subscriptionID: SubscriptionID)

    /// Used for authentication (NIP-42)
    case auth(Event)

    /// Used to request the number of events matching the filters (NIP-45).
    /// https://github.com/nostr-protocol/nips/blob/master/45.md
    case count(subscriptionID: SubscriptionID, filters: [Filter])

    /// Serializes the message to JSON array format
    public func serialize() -> String {
        let array: [Any]

        switch self {
        case .event(let event):
            let eventDict = event.jsonObject()
            array = ["EVENT", eventDict]

        case .request(let subscriptionID, let filters):
            var arr: [Any] = ["REQ", subscriptionID.rawValue]
            for filter in filters {
                let filterDict = filter.jsonObject()
                arr.append(filterDict)
            }
            array = arr

        case .close(let subscriptionID):
            array = ["CLOSE", subscriptionID.rawValue]

        case .auth(let event):
            let eventDict = event.jsonObject()
            array = ["AUTH", eventDict]

        case .count(let subscriptionID, let filters):
            var arr: [Any] = ["COUNT", subscriptionID.rawValue]
            for filter in filters {
                let filterDict = filter.jsonObject()
                arr.append(filterDict)
            }
            array = arr
        }

        // Strings and decoded JSON objects always serialize, and `JSONSerialization` writes UTF-8.
        do {
            let data = try JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        } catch {
            preconditionFailure("A client message did not serialize as JSON: \(error)")
        }
    }
}

/// Messages received from a relay (NIP-01)
public enum RelayMessage: Sendable, Hashable {
    /// Event sent by the relay
    case event(subscriptionID: SubscriptionID, event: Event)

    /// End of stored events notice
    case endOfStoredEvents(subscriptionID: SubscriptionID)

    /// Notice message from the relay
    case notice(message: String)

    /// OK response for an event (NIP-01): whether the relay accepted the event with id
    /// `eventID`, and its status message.
    case ok(eventID: EventID, accepted: Bool, message: String)

    /// Authentication challenge (NIP-42)
    case auth(challenge: String)

    /// Closed subscription notice
    case closed(subscriptionID: SubscriptionID, message: String)

    /// Count of events matching the requested filters (NIP-45); a payload without the
    /// `approximate` flag is an exact count.
    /// https://github.com/nostr-protocol/nips/blob/master/45.md
    case count(subscriptionID: SubscriptionID, count: EventCount)

    /// Unknown message type
    case unknown(type: String, rawData: String)

    /// Parses a raw JSON frame received from a relay.
    ///
    /// - Throws: ``RelayMessage/Error/malformed`` if the frame is not a JSON array or lacks the
    ///   fields its type requires — including an `OK` whose event id is not canonical 64-digit
    ///   lowercase hex, which cannot answer any event this client sent, and an `EVENT` carrying a
    ///   malformed event.
    public init(json: String) throws(RelayMessage.Error) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let array = object as? [Any],
            let type = array.first as? String
        else {
            throw .malformed
        }

        switch type {
        case "EVENT":
            guard array.count >= 3,
                let subscriptionID = (array[1] as? String).map(SubscriptionID.init(rawValue:)),
                let eventDict = array[2] as? [String: Any]
            else {
                throw .malformed
            }
            guard let event = try? Event(jsonObject: eventDict) else {
                throw .malformed
            }
            self = .event(subscriptionID: subscriptionID, event: event)

        case "EOSE":
            guard array.count >= 2,
                let subscriptionID = (array[1] as? String).map(SubscriptionID.init(rawValue:))
            else {
                throw .malformed
            }
            self = .endOfStoredEvents(subscriptionID: subscriptionID)

        case "NOTICE":
            guard array.count >= 2,
                let message = array[1] as? String
            else {
                throw .malformed
            }
            self = .notice(message: message)

        case "OK":
            guard array.count >= 4,
                let eventID = (array[1] as? String).flatMap(EventID.init),
                let accepted = array[2] as? Bool,
                let message = array[3] as? String
            else {
                throw .malformed
            }
            self = .ok(eventID: eventID, accepted: accepted, message: message)

        case "AUTH":
            guard array.count >= 2,
                let challenge = array[1] as? String
            else {
                throw .malformed
            }
            self = .auth(challenge: challenge)

        case "CLOSED":
            guard array.count >= 3,
                let subscriptionID = (array[1] as? String).map(SubscriptionID.init(rawValue:)),
                let message = array[2] as? String
            else {
                throw .malformed
            }
            self = .closed(subscriptionID: subscriptionID, message: message)

        case "COUNT":
            // The payload carries `count` and an optional `approximate` flag; any
            // other keys (e.g. the NIP-45 `hll` HyperLogLog value) are ignored.
            guard array.count >= 3,
                let subscriptionID = (array[1] as? String).map(SubscriptionID.init(rawValue:)),
                let payload = array[2] as? [String: Any],
                let count = payload["count"] as? Int
            else {
                throw .malformed
            }
            let isApproximate = payload["approximate"] as? Bool ?? false
            let eventCount = EventCount(value: count, isApproximate: isApproximate)
            self = .count(subscriptionID: subscriptionID, count: eventCount)

        default:
            self = .unknown(type: type, rawData: json)
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
    fileprivate func jsonObject() -> [String: Any] {
        // No key strategy: every declared key already carries its NIP-01 wire spelling
        // (`created_at`, `#e`, `#p`), so converting would be a no-op for them — while corrupting
        // the dynamic keys `Filter` emits for generic tag queries. Converting to snake case turns
        // the uppercase tags NIP-22 uses for root scope (`#A`, `#E`, `#I`, `#K`, `#P`) into `#_a`
        // and friends, which a relay does not recognize: it drops the unknown key and answers the
        // rest of the filter, silently returning more than was asked for.
        // Only `Event` and `Filter` come through here: keyed containers of strings, integers, and
        // arrays of them, which always encode.
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        } catch {
            preconditionFailure("\(Self.self) did not encode as JSON: \(error)")
        }
        guard let dict = object as? [String: Any] else {
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
