import Foundation

/// A decoded BOLT-11 Lightning invoice, exposing the fields NIP-57 zap validation relies on.
///
/// This validates the invoice's bech32 checksum but does **not** verify its payee (node) signature:
/// for a zap receipt the trust anchor is the kind-9735 event's own signature (see ``ZapReceipt``),
/// not the invoice's. Fields the validation does not need — routing hints, fallback address, feature
/// bits, the signature — are skipped.
/// https://github.com/lightning/bolts/blob/master/11-payment-encoding.md
public struct Bolt11Invoice: Sendable, Hashable {
    /// The amount in millisatoshis, or nil for an amountless invoice.
    public let amountMillisats: Int64?

    /// The time the invoice was created.
    public let timestamp: Date

    /// The payment hash (the `p` field, 32 bytes), if present.
    public let paymentHash: Data?

    /// The description hash (the `h` field, 32 bytes), if present — the SHA-256 of the payment
    /// description. For zaps this is the hash of the JSON-encoded zap request (LUD-12 / NIP-57).
    public let descriptionHash: Data?

    /// The short description (the `d` field), if present.
    public let description: String?

    /// The number of seconds after ``timestamp`` at which the invoice expires (the `x` field), if present.
    public let expirySeconds: Int64?

    /// Parses a BOLT-11 invoice string (e.g. `lnbc2500u1...`).
    /// - Returns: nil if the string is not a valid BOLT-11 invoice — a bad checksum, malformed
    ///   structure, or an out-of-range amount.
    public init?(_ invoice: String) {
        guard let (hrp, words) = try? Bech32.decodeToWords(invoice), hrp.hasPrefix("ln") else {
            return nil
        }

        switch Self.parseAmount(hrp: hrp) {
        case .invalid:
            return nil
        case .amountless:
            self.amountMillisats = nil
        case .value(let millisats):
            self.amountMillisats = millisats
        }

        // Data layout: a 35-bit (7-word) timestamp, then tagged fields, then a 520-bit (104-word)
        // signature that this parser does not read.
        guard words.count >= Self.timestampWordCount + Self.signatureWordCount else {
            return nil
        }
        self.timestamp = Date(
            timeIntervalSince1970: TimeInterval(Self.integer(from: words[0..<Self.timestampWordCount])))

        var paymentHash: Data?
        var descriptionHash: Data?
        var description: String?
        var expirySeconds: Int64?

        let fieldsEnd = words.count - Self.signatureWordCount
        var index = Self.timestampWordCount
        // Each tagged field is a 1-word type, a 2-word length (counting data words), then the data.
        while index + 3 <= fieldsEnd {
            let type = words[index]
            let length = Int(words[index + 1]) << 5 | Int(words[index + 2])
            let dataStart = index + 3
            let dataEnd = dataStart + length
            guard dataEnd <= fieldsEnd else {
                break  // A length that overruns the field section means the invoice is malformed.
            }
            let field = words[dataStart..<dataEnd]

            // Per BOLT-11, when a field type repeats the first occurrence wins, so each case only
            // assigns while still unset.
            switch type {
            case FieldType.paymentHash:
                // Readers MUST skip a p/h field whose length is not exactly 52 words (256 bits).
                if paymentHash == nil, length == Self.hashWordCount {
                    paymentHash = Data(Bech32.wordsToBytes(Array(field)))
                }
            case FieldType.descriptionHash:
                if descriptionHash == nil, length == Self.hashWordCount {
                    descriptionHash = Data(Bech32.wordsToBytes(Array(field)))
                }
            case FieldType.description:
                if description == nil {
                    description = String(data: Data(Bech32.wordsToBytes(Array(field))), encoding: .utf8)
                }
            case FieldType.expiry:
                // Cap at 12 words (60 bits) so an oversized field can't fold into a truncated,
                // garbage value; a real expiry is only a few words.
                if expirySeconds == nil, field.count <= 12 {
                    expirySeconds = Int64(exactly: Self.integer(from: field))
                }
            default:
                break  // A field this parser does not need.
            }
            index = dataEnd
        }

        self.paymentHash = paymentHash
        self.descriptionHash = descriptionHash
        self.description = description
        self.expirySeconds = expirySeconds
    }
}

// MARK: - Parsing helpers

extension Bolt11Invoice {
    /// The number of 5-bit words holding the creation timestamp (35 bits).
    private static let timestampWordCount = 7

    /// The number of 5-bit words holding the signature (a 520-bit recoverable signature).
    private static let signatureWordCount = 104

    /// The number of 5-bit words holding a 256-bit hash (52 × 5 = 260 bits, the last 4 padding).
    private static let hashWordCount = 52

    /// BOLT-11 tagged-field type codes (the 5-bit value preceding each field).
    private enum FieldType {
        static let paymentHash: UInt8 = 1  // "p"
        static let expiry: UInt8 = 6  // "x"
        static let description: UInt8 = 13  // "d"
        static let descriptionHash: UInt8 = 23  // "h"
    }

    /// The outcome of reading the amount from the human-readable part.
    private enum ParsedAmount {
        case value(Int64)
        case amountless
        case invalid
    }

    /// Reads the amount from the human-readable part (`ln` + currency prefix + optional amount).
    ///
    /// The amount is `digits` followed by an optional multiplier — `m`illi (1e-3), `u`micro (1e-6),
    /// `n`ano (1e-9), or `p`ico (1e-12) bitcoin — converted to millisatoshis (1 BTC = 1e11 msats).
    /// All arithmetic is overflow-checked, and a `p` amount must be a multiple of 10 (BOLT-11), so
    /// the result is always an integer number of millisatoshis.
    private static func parseAmount(hrp: String) -> ParsedAmount {
        // Strip "ln" and the longest matching currency prefix; the remainder is the amount token.
        let afterLN = hrp.dropFirst(2)
        let currencyPrefixes = ["bcrt", "tbs", "tb", "bc"]
        guard let prefix = currencyPrefixes.first(where: { afterLN.hasPrefix($0) }) else {
            return .invalid
        }
        let amountToken = afterLN.dropFirst(prefix.count)
        if amountToken.isEmpty {
            return .amountless
        }

        // msats = digits * numerator / denominator. Whole bitcoin = 1e11 msats; each multiplier
        // shifts that down by three orders of magnitude, with pico landing on a tenth of a msat.
        let digits: Substring
        let numerator: UInt64
        let denominator: UInt64
        switch amountToken.last {
        case "m": (digits, numerator, denominator) = (amountToken.dropLast(), 100_000_000, 1)
        case "u": (digits, numerator, denominator) = (amountToken.dropLast(), 100_000, 1)
        case "n": (digits, numerator, denominator) = (amountToken.dropLast(), 100, 1)
        case "p": (digits, numerator, denominator) = (amountToken.dropLast(), 1, 10)
        default: (digits, numerator, denominator) = (amountToken, 100_000_000_000, 1)
        }

        guard !digits.isEmpty, let value = UInt64(digits) else {
            return .invalid
        }
        let (product, overflowed) = value.multipliedReportingOverflow(by: numerator)
        guard !overflowed, product % denominator == 0 else {
            return .invalid
        }
        let millisats = product / denominator
        guard millisats <= UInt64(Int64.max) else {
            return .invalid
        }
        return .value(Int64(millisats))
    }

    /// Folds a run of 5-bit words into an integer, most-significant word first.
    private static func integer(from words: ArraySlice<UInt8>) -> UInt64 {
        words.reduce(UInt64(0)) { ($0 << 5) | UInt64($1) }
    }
}
