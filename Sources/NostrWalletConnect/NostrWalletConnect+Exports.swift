// This file makes `import NostrWalletConnect` the single import point for the library.
//
// NostrCore's primitives (`Event`, `EventSigner`, `LNURLPayResponse`, `NostrError`, ...)
// are re-exported because the NostrWalletConnect API surfaces them; Foundation is
// re-exported for the Foundation types (`Date`, `Data`, `URL`, ...) that appear in the
// same API.
@_exported import Foundation
@_exported import NostrCore
