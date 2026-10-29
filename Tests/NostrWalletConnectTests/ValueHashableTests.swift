import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrWalletConnect

@Suite("Value Hashable Tests")
struct ValueHashableTests {
    private static let paid = PaymentResult(preimage: "aa", feesPaid: 1)
    private static let declined = WalletConnectError.walletError(code: .insufficientBalance, message: "low")

    static let samples: [HashableSample] = [
        HashableSample(
            "WalletConnectError", WalletConnectError.transportFailed(.timedOut),
            WalletConnectError.transportFailed(.timedOut), WalletConnectError.transportFailed(.notConnected)),
        HashableSample(
            "MultiPayOutcome", MultiPayOutcome.answered(.success(paid)), MultiPayOutcome.answered(.success(paid)),
            MultiPayOutcome.answered(.failure(declined))),
        HashableSample(
            "UnmatchedMultiPayResponse", UnmatchedMultiPayResponse(dTag: "a", result: .success(paid)),
            UnmatchedMultiPayResponse(dTag: "a", result: .success(paid)),
            UnmatchedMultiPayResponse(dTag: "b", result: .success(paid))),
        HashableSample(
            "MultiPayResults", MultiPayResults(outcomes: [.noResponse]), MultiPayResults(outcomes: [.noResponse]),
            MultiPayResults(outcomes: [.answered(.success(paid))])),
        HashableSample(
            "WalletConnection.Config", WalletConnection.Config(), WalletConnection.Config(),
            WalletConnection.Config(preferredEncryption: .nip44)),
    ]

    @Test("equal values are equal, hash alike, and collapse in a Set", arguments: samples)
    func hashable(sample: HashableSample) {
        #expect(sample.equalValuesAreEqual)
        #expect(sample.equalValuesHashAlike)
        #expect(sample.differentValueIsUnequal)
        #expect(sample.setCount == 2)
    }
}
