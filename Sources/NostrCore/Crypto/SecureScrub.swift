import Foundation

extension Data {
    /// Overwrites this buffer's bytes with zeros.
    ///
    /// Use it through `defer` on the intermediate key material a derivation produces — conversation
    /// keys, message keys, scrypt output — so a copy does not sit in freed memory after the
    /// operation that needed it has finished. It narrows the window in which a heap disclosure or a
    /// core dump would find a usable key; it is not a defense against an attacker who can read the
    /// process while the key is in use.
    ///
    /// Two limits are worth stating plainly, because this cannot be made airtight in Swift:
    ///
    /// - `Data` is copy-on-write. Scrubbing zeroes the buffer this value refers to, so any copy
    ///   made earlier that still shares it is zeroed too — which is the point — but a copy that has
    ///   already diverged is untouched. Scrub the value that owns the bytes, not one derived from it.
    /// - `String` secrets cannot be scrubbed at all: they may be shared, small-string-optimized, or
    ///   moved by the runtime, and there is no way to reach every copy. A mnemonic or a decrypted
    ///   `nsec` held as a `String` stays in memory until the runtime reclaims it.
    mutating func secureScrub() {
        guard !isEmpty else { return }
        // `resetBytes(in:)` writes through Foundation rather than a local loop the optimizer could
        // drop as dead, since nothing reads the buffer afterwards.
        resetBytes(in: startIndex..<endIndex)
    }
}
