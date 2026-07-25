// This file makes `import NostrConnect` the single import point for the library.
//
// NostrCore's primitives (`Event`, `KeyPair`, `UnsignedEvent`, `NostrError`, ...) are
// re-exported because the NostrConnect API surfaces them; Foundation is re-exported
// for the Foundation types (`Date`, `Data`, `URL`, ...) that appear in the same API.
@_exported import Foundation
@_exported import NostrCore
