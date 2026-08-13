import Foundation

/// What became of one item in a `multi_pay_invoice` or `multi_pay_keysend` request.
public enum MultiPayOutcome<Item: Sendable>: Sendable {
    /// The wallet answered for this item: the payment result, or the error it reported.
    case answered(Result<Item, WalletConnectError>)
    /// No response arrived that could be tied to this item.
    ///
    /// Either the wallet did not answer it before the request completed, or its answer is in
    /// ``MultiPayResults/unmatched`` because nothing tied it back — see there for when that happens.
    case noResponse

    /// The payment result, if the wallet answered successfully.
    public var value: Item? {
        guard case .answered(.success(let item)) = self else { return nil }
        return item
    }

    /// The error, if the wallet answered with one.
    public var error: WalletConnectError? {
        guard case .answered(.failure(let error)) = self else { return nil }
        return error
    }
}

/// A response the wallet sent that could not be tied to a requested item.
public struct UnmatchedMultiPayResponse<Item: Sendable>: Sendable {
    /// The `d` tag the wallet correlated the response by, if it sent one.
    ///
    /// NIP-47 sets this to the item's `id` when the request supplied one, and otherwise to the
    /// payment hash — which this package cannot derive from an invoice, so a response for an item
    /// sent without an `id` arrives here rather than matched. Supply an `id` per item to have every
    /// response matched.
    public let dTag: String?
    /// The payment result, or the error the wallet reported.
    public let result: Result<Item, WalletConnectError>

    public init(dTag: String?, result: Result<Item, WalletConnectError>) {
        self.dTag = dTag
        self.result = result
    }
}

/// The outcome of a `multi_pay_*` request: one entry per requested item, in the order requested.
///
/// Ordered rather than keyed because a `d` tag does not identify a request item on its own — two
/// items can share one, and an item sent without an `id` is answered under a payment hash the
/// caller would have to derive. Keying by it silently dropped a colliding result and left no way to
/// tell which invoice a result belonged to; here nothing is lost, and anything that could not be
/// tied back is reported in ``unmatched`` instead of being discarded.
public struct MultiPayResults<Item: Sendable>: Sendable {
    /// One outcome per requested item, aligned to the order they were requested in.
    public let outcomes: [MultiPayOutcome<Item>]

    /// Responses that could not be tied to a requested item — a `d` tag matching none of them, a
    /// duplicate of one already matched, or a response for an item sent without an `id`.
    ///
    /// Usually empty. When it is not, the payments it describes still happened.
    public let unmatched: [UnmatchedMultiPayResponse<Item>]

    public init(outcomes: [MultiPayOutcome<Item>], unmatched: [UnmatchedMultiPayResponse<Item>] = []) {
        self.outcomes = outcomes
        self.unmatched = unmatched
    }

    /// Whether every requested item was answered successfully.
    public var isCompletelySuccessful: Bool {
        unmatched.isEmpty && outcomes.allSatisfy { $0.value != nil }
    }

    /// The items the wallet did not answer.
    public var indicesWithoutResponse: [Int] {
        outcomes.enumerated().compactMap { index, outcome in
            if case .noResponse = outcome { return index }
            return nil
        }
    }
}
