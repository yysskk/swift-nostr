import NostrCore

// Parsing for the hex keys and ids that NostrClient's string-typed APIs take from callers.
//
// Those APIs have always accepted either case, since an uppercase spelling names the same key or
// event as the canonical lowercase one, so the string is lowercased before the strict parse.

extension PublicKey {
    /// Parses a caller-supplied hex public key of either case.
    /// - Throws: ``NostrError/invalidPublicKey`` if `hex` is not 64 hexadecimal digits.
    init(callerHex hex: String) throws {
        try self.init(hex: hex.lowercased())
    }
}

extension EventID {
    /// Parses a caller-supplied hex event id of either case.
    /// - Throws: ``NostrError/invalidEventID`` if `hex` is not 64 hexadecimal digits.
    init(callerHex hex: String) throws {
        try self.init(hex: hex.lowercased())
    }
}
