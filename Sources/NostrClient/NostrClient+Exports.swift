// This file makes `import NostrClient` the single import point for the library.
//
// NostrCore's primitives (`Event`, `KeyPair`, `EventSigner`, `Filter`, `Bech32`,
// `RelayConnection`, `NostrError`, ...) are re-exported because the NostrClient API
// surfaces them; Foundation is re-exported for the Foundation types (`Date`, `Data`,
// `URL`, ...) that appear in the same API.
@_exported import Foundation
@_exported import NostrCore
