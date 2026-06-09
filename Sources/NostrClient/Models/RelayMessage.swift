import Foundation

/// Messages sent from the client to a relay (NIP-01)
public enum ClientMessage: Sendable {
    /// Used to publish events
    case event(Event)

    /// Used to request events and subscribe
    case request(subscriptionId: String, filters: [Filter])

    /// Used to stop a subscription
    case close(subscriptionId: String)

    /// Used for authentication (NIP-42)
    case auth(Event)

    /// Serializes the message to JSON array format
    public func serialize() throws -> String {
        let array: [Any]

        switch self {
        case .event(let event):
            let eventDict = try event.toDictionary()
            array = ["EVENT", eventDict]

        case .request(let subscriptionId, let filters):
            var arr: [Any] = ["REQ", subscriptionId]
            for filter in filters {
                let filterDict = try filter.toDictionary()
                arr.append(filterDict)
            }
            array = arr

        case .close(let subscriptionId):
            array = ["CLOSE", subscriptionId]

        case .auth(let event):
            let eventDict = try event.toDictionary()
            array = ["AUTH", eventDict]
        }

        let data = try JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes])
        guard let string = String(data: data, encoding: .utf8) else {
            throw NostrError.serializationFailed
        }
        return string
    }
}

/// Messages received from a relay (NIP-01)
public enum RelayMessage: Sendable {
    /// Event sent by the relay
    case event(subscriptionId: String, event: Event)

    /// End of stored events notice
    case endOfStoredEvents(subscriptionId: String)

    /// Notice message from the relay
    case notice(message: String)

    /// OK response for an event (NIP-20)
    case ok(eventId: String, accepted: Bool, message: String)

    /// Authentication challenge (NIP-42)
    case auth(challenge: String)

    /// Closed subscription notice
    case closed(subscriptionId: String, message: String)

    /// Unknown message type
    case unknown(type: String, rawData: String)

    /// Parses a raw JSON message from a relay
    public static func parse(_ text: String) throws -> RelayMessage {
        guard let data = text.data(using: .utf8) else {
            throw NostrError.invalidData
        }

        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            let type = array.first as? String
        else {
            throw NostrError.invalidMessageFormat
        }

        switch type {
        case "EVENT":
            guard array.count >= 3,
                let subscriptionId = array[1] as? String,
                let eventDict = array[2] as? [String: Any]
            else {
                throw NostrError.invalidMessageFormat
            }
            let event = try Event.from(dictionary: eventDict)
            return .event(subscriptionId: subscriptionId, event: event)

        case "EOSE":
            guard array.count >= 2,
                let subscriptionId = array[1] as? String
            else {
                throw NostrError.invalidMessageFormat
            }
            return .endOfStoredEvents(subscriptionId: subscriptionId)

        case "NOTICE":
            guard array.count >= 2,
                let message = array[1] as? String
            else {
                throw NostrError.invalidMessageFormat
            }
            return .notice(message: message)

        case "OK":
            guard array.count >= 4,
                let eventId = array[1] as? String,
                let accepted = array[2] as? Bool,
                let message = array[3] as? String
            else {
                throw NostrError.invalidMessageFormat
            }
            return .ok(eventId: eventId, accepted: accepted, message: message)

        case "AUTH":
            guard array.count >= 2,
                let challenge = array[1] as? String
            else {
                throw NostrError.invalidMessageFormat
            }
            return .auth(challenge: challenge)

        case "CLOSED":
            guard array.count >= 3,
                let subscriptionId = array[1] as? String,
                let message = array[2] as? String
            else {
                throw NostrError.invalidMessageFormat
            }
            return .closed(subscriptionId: subscriptionId, message: message)

        default:
            return .unknown(type: type, rawData: text)
        }
    }
}

// MARK: - Codable Helpers
extension Encodable {
    fileprivate func toDictionary() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(self)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrError.serializationFailed
        }
        return dict
    }
}

extension Event {
    fileprivate static func from(dictionary: [String: Any]) throws -> Event {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let decoder = JSONDecoder()
        return try decoder.decode(Event.self, from: data)
    }
}
