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
    ///
    /// Nil when the request carries no `amount` tag *or* when its value is not a number; use
    /// ``validate(lnurlProviderPubkey:expectedAmountMillisats:requiringDescriptionHash:)`` to tell
    /// those apart, since it rejects a malformed amount rather than treating it as absent.
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
        /// The invoice carries no description hash, so nothing ties it to the receipt's zap request.
        case missingDescriptionHash
        /// The invoice amount does not match the zap request or the expected amount.
        case amountMismatch
        /// An amount was expected, but the invoice names none to check it against.
        case missingAmount
        /// The zap request's `amount` tag is not a number.
        case invalidAmount
        /// The receipt has no `p` tag, so it does not say who was zapped (NIP-57 requires one).
        case missingRecipient
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
            case .missingDescriptionHash:
                return "The invoice does not commit to a description hash, so it is not bound to the zap request"
            case .amountMismatch:
                return "The invoice amount does not match the zap request"
            case .missingAmount:
                return "An amount was expected but the invoice does not name one"
            case .invalidAmount:
                return "The zap request's amount is not a number"
            case .missingRecipient:
                return "The zap receipt has no p tag naming who was zapped"
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
    /// The trust anchor is the receipt's own signature by the provider's key. Once that is verified,
    /// the invoice is required to commit to the receipt's zap request through its description hash,
    /// which is what ties the invoice actually paid to the zap that was asked for; the amounts,
    /// recipient, zapped event, and preimage are then cross-checked. The embedded zap request's own
    /// signature is intentionally not required — some providers re-serialize it — so authenticity
    /// rests on the provider's signature, not the sender's.
    ///
    /// A check that cannot be made is reported rather than skipped: passing
    /// `expectedAmountMillisats` for an invoice that names no amount fails, because the assertion
    /// the caller asked for cannot be established.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    /// - Parameters:
    ///   - lnurlProviderPubkey: The `nostrPubkey` from the recipient's ``LNURLPayResponse`` — the key
    ///     the provider signs receipts with.
    ///   - expectedAmountMillisats: The amount you requested. When given, the invoice must name an
    ///     amount and it must match.
    ///   - requiringDescriptionHash: Whether the invoice must commit to the zap request through its
    ///     description hash (default `true`). LUD-06 and LUD-12 make that hash part of the
    ///     LNURL-pay flow every zap goes through, so a receipt lacking it proves only that the
    ///     provider signed *some* invoice alongside *some* zap request. Pass `false` only when a
    ///     provider is known to omit it and you accept losing that binding.
    /// - Throws: ``ValidationError`` if any check fails.
    public func validate(
        lnurlProviderPubkey: String,
        expectedAmountMillisats: Int64? = nil,
        requiringDescriptionHash: Bool = true
    ) throws {
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

        // 5. The invoice's description hash is what binds it to this zap request — without it the
        //    receipt pairs an invoice and a request that need have nothing to do with each other.
        if let descriptionHash = invoice.descriptionHash {
            guard descriptionHash == Data(SHA256.hash(data: Data(descriptionJSON.utf8))) else {
                throw ValidationError.descriptionHashMismatch
            }
        } else if requiringDescriptionHash {
            throw ValidationError.missingDescriptionHash
        }

        // 6. Amounts must agree. A malformed `amount` is rejected rather than read as absent, and an
        //    amount the caller asked us to confirm cannot be confirmed against an amountless invoice.
        let requestAmount: Int64?
        if let rawAmount = zapRequest?.firstTagValue(named: "amount") {
            guard let parsed = Int64(rawAmount) else { throw ValidationError.invalidAmount }
            requestAmount = parsed
        } else {
            requestAmount = nil
        }

        if let invoiceAmount = invoice.amountMillisats {
            if let requestAmount, requestAmount != invoiceAmount {
                throw ValidationError.amountMismatch
            }
            if let expectedAmountMillisats, expectedAmountMillisats != invoiceAmount {
                throw ValidationError.amountMismatch
            }
        } else if expectedAmountMillisats != nil {
            throw ValidationError.missingAmount
        }

        // 7. NIP-57 requires the receipt to name who was zapped, and it must be the same recipient
        //    and event the request named, so a provider cannot redirect a zap to a different
        //    `p`/`e` than the sender asked for.
        guard let receiptRecipient = recipientPubkey else {
            throw ValidationError.missingRecipient
        }
        if let zapRequest {
            if let requestRecipient = zapRequest.firstTagValue(named: "p"),
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
