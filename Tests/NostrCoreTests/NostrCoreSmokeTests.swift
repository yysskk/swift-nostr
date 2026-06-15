import NostrCore
import Testing

@Suite("NostrCore Module")
struct NostrCoreSmokeTests {
    /// Confirms the `NostrCore` target builds and the test target links against
    /// it. Real coverage arrives with the primitives that migrate into the
    /// module in subsequent changes.
    @Test("module builds and links")
    func moduleBuildsAndLinks() {
        #expect(true)
    }
}
