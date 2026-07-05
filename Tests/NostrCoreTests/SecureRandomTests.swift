import Foundation
import Testing

@testable import NostrCore

@Suite("SecureRandom Tests")
struct SecureRandomTests {

    @Test("Generates the requested number of bytes")
    func generatesRequestedCount() throws {
        let bytes = try SecureRandom.generateBytes(count: 32)

        #expect(bytes.count == 32)
    }

    @Test("A count of zero yields empty data")
    func zeroCountIsEmpty() throws {
        let bytes = try SecureRandom.generateBytes(count: 0)

        #expect(bytes.isEmpty)
    }

    @Test("Two calls produce different bytes")
    func callsAreDistinct() throws {
        let first = try SecureRandom.generateBytes(count: 32)
        let second = try SecureRandom.generateBytes(count: 32)

        // A collision between two 32-byte CSPRNG draws is astronomically unlikely.
        #expect(first != second)
    }
}
