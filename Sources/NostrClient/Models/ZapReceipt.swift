import Crypto
import Foundation
import NostrCore

/// A NIP-57 zap receipt (kind 9735): the event a recipient's LNURL provider publishes once a zap
/// invoice has been paid, attesting to the payment.
///
/// Wrap a kind-9735 event to read its fields, then call
/// ``validate(lnurlProviderPubkey:expectedAmountMillisats:)`` to confirm the receipt is authentic and
/// matches the zap you requested.
/// https://github.com/nostr-protocol/nips/blob/master/57.md
public struct ZapReceipt: Sendable, Hashable {
    /// The underlying kind-9735 event.
    public let event: Event

    /// The zap request (kind 9734) embedded in the `description` tag, if it decodes as an event.
    public let zapRequest: Event?

    /// Wraps a kind-9735 event. Returns nil if `event` is not a zap receipt.
    public init?(event: Event) {
        guard event.kind == .zap else { return nil }
        self.event = event
        // Decode the embedded zap request once, rather than on every property access.
        if let descriptionJSON = event.firstTagValue(named: "description") {
            self.zapRequest = try? JSONDecoder().decode(Event.self, from: Data(descriptionJSON.utf8))
        } else {
            self.zapRequest = nil
        }
    }

    /// The bolt11 invoice that was paid (the `bolt11` tag).
    public var bolt11: String? { event.firstTagValue(named: "bolt11") }

    /// The payment preimage proving the invoice was paid (the `preimage` tag), if provided.
    public var preimage: String? { event.firstTagValue(named: "preimage") }

    /// The zap request the provider echoed back (the `description` tag), as its raw JSON string.
    public var descriptionJSON: String? { event.firstTagValue(named: "description") }

    /// The pubkey that was zapped (the `p` tag).
    public var recipientPubkey: String? { event.firstTagValue(named: "p") }

    /// The pubkey that sent the zap (the uppercase `P` tag), if provided.
    public var senderPubkey: String? { event.firstTagValue(named: "P") }

    /// The id of the event that was zapped (the `e` tag), if the zap targeted an event.
    public var zappedEventId: String? { event.firstTagValue(named: "e") }

    /// The coordinate of the addressable event that was zapped (the `a` tag), if any.
    public var zappedEventCoordinate: String? { event.firstTagValue(named: "a") }

    /// The zapped amount in millisatoshis, taken from the embedded zap request's `amount` tag.
    public var amountMillisats: Int64? {
        guard let value = zapRequest?.firstTagValue(named: "amount") else { return nil }
        return Int64(value)
    }
}

// MARK: - Validation

extension ZapReceipt {
    /// The reason a zap receipt failed ``ZapReceipt/validate(lnurlProviderPubkey:expectedAmountMillisats:)``.
    public enum ValidationError: Error, LocalizedError, Sendable, Equatable {
        /// The receipt was not signed by the recipient's LNURL provider.
        case payeePubkeyMismatch
        /// The receipt's signature is invalid.
        case invalidSignature
        /// The receipt has no `bolt11` tag.
        case missingBolt11
        /// The receipt has no `description` tag.
        case missingDescription
        /// The `bolt11` invoice could not be parsed.
        case invalidBolt11
        /// The invoice's description hash does not match the receipt's description.
        case descriptionHashMismatch
        /// The invoice amount does not match the zap request or the expected amount.
        case amountMismatch
        /// The receipt's `p` tag does not match the zap request's recipient.
        case recipientMismatch
        /// The receipt's `e` tag does not match the event the zap request zapped.
        case zappedEventMismatch
        /// The preimage does not hash to the invoice's payment hash.
        case preimageMismatch

        public var errorDescription: String? {
            switch self {
            case .payeePubkeyMismatch:
                return "The zap receipt was not signed by the recipient's LNURL provider"
            case .invalidSignature:
                return "The zap receipt signature is invalid"
            case .missingBolt11:
                return "The zap receipt has no bolt11 invoice"
            case .missingDescription:
                return "The zap receipt has no description"
            case .invalidBolt11:
                return "The zap receipt's bolt11 invoice could not be parsed"
            case .descriptionHashMismatch:
                return "The invoice description hash does not match the zap request"
            case .amountMismatch:
                return "The invoice amount does not match the zap request"
            case .recipientMismatch:
                return "The zap receipt recipient does not match the zap request"
            case .zappedEventMismatch:
                return "The zapped event does not match the zap request"
            case .preimageMismatch:
                return "The preimage does not match the invoice payment hash"
            }
        }
    }

    /// Validates the zap receipt against the recipient's LNURL provider and, optionally, the amount
    /// you requested.
    ///
    /// The trust anchor is the receipt's own signature by the provider's key: once that is verified,
    /// the bolt11 amount, description hash, and preimage are cross-checked when the invoice carries
    /// them. The embedded zap request's own signature is intentionally not required — some providers
    /// re-serialize it — so authenticity rests on the provider's signature, not the sender's.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    /// - Parameters:
    ///   - lnurlProviderPubkey: The `nostrPubkey` from the recipient's ``LNURLPayResponse`` — the key
    ///     the provider signs receipts with.
    ///   - expectedAmountMillisats: The amount you requested, checked against the invoice when given.
    /// - Throws: ``ValidationError`` if any check fails.
    public func validate(lnurlProviderPubkey: String, expectedAmountMillisats: Int64? = nil) throws {
        // 1. The receipt must claim to come from the provider's key.
        guard event.pubkey.lowercased() == lnurlProviderPubkey.lowercased() else {
            throw ValidationError.payeePubkeyMismatch
        }

        // 2. Required tags must be present.
        guard let bolt11 else { throw ValidationError.missingBolt11 }
        guard let descriptionJSON else { throw ValidationError.missingDescription }

        // 3. The signature confirms the provider really issued this receipt — the trust anchor, so
        //    it is checked before the receipt's contents (including the bolt11) are trusted.
        guard (try? event.verify()) == true else { throw ValidationError.invalidSignature }

        // 4. The invoice must parse.
        guard let invoice = Bolt11Invoice(bolt11) else { throw ValidationError.invalidBolt11 }

        // 5. If the invoice commits to a description hash, it must be the hash of the receipt's
        //    description (the exact tag string, hashed as-is).
        if let descriptionHash = invoice.descriptionHash {
            guard descriptionHash == Data(SHA256.hash(data: Data(descriptionJSON.utf8))) else {
                throw ValidationError.descriptionHashMismatch
            }
        }

        // 6. Amounts must agree where present. An amountless invoice is advisory and never fails.
        if let invoiceAmount = invoice.amountMillisats {
            if let requestAmount = amountMillisats, requestAmount != invoiceAmount {
                throw ValidationError.amountMismatch
            }
            if let expectedAmountMillisats, expectedAmountMillisats != invoiceAmount {
                throw ValidationError.amountMismatch
            }
        }

        // 7. The receipt must zap the same recipient and event as the request (NIP-57), so a provider
        //    cannot redirect a zap to a different `p`/`e` than the sender asked for.
        if let zapRequest {
            if let receiptRecipient = recipientPubkey,
                let requestRecipient = zapRequest.firstTagValue(named: "p"),
                receiptRecipient != requestRecipient
            {
                throw ValidationError.recipientMismatch
            }
            if let receiptEvent = zappedEventId,
                let requestEvent = zapRequest.firstTagValue(named: "e"),
                receiptEvent != requestEvent
            {
                throw ValidationError.zappedEventMismatch
            }
        }

        // 8. A preimage, when present, must hash to the invoice's payment hash.
        if let preimage, let paymentHash = invoice.paymentHash {
            guard let preimageData = Data(hexString: preimage),
                Data(SHA256.hash(data: preimageData)) == paymentHash
            else {
                throw ValidationError.preimageMismatch
            }
        }
    }
}
