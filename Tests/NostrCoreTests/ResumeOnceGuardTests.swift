import Foundation
import Testing

@testable import NostrCore

@Suite("ResumeOnceGuard Tests")
struct ResumeOnceGuardTests {
    @Test("First claim wins, subsequent claims lose (sequential)")
    func sequentialClaim() {
        let guardObject = ResumeOnceGuard()
        #expect(guardObject.claim() == true)
        #expect(guardObject.claim() == false)
        #expect(guardObject.claim() == false)
    }

    @Test("Exactly one claim wins under concurrent access")
    func onlyOneClaimWinsConcurrently() async {
        for _ in 0..<1_000 {
            let guardObject = ResumeOnceGuard()
            let winners = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<32 { group.addTask { guardObject.claim() } }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            #expect(winners == 1)
        }
    }
}
