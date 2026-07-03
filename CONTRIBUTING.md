# Contributing to Swift Nostr

Thank you for your interest in contributing! Bug reports, feature requests, documentation
improvements, and pull requests are all welcome.

## Getting started

You need Swift 6.3 or later (bundled with a recent Xcode on Apple platforms, or the
[swift.org](https://www.swift.org/install/) toolchain on Linux).

```bash
git clone https://github.com/yysskk/swift-nostr.git
cd swift-nostr
swift build
swift test
```

The package vends three libraries — `NostrCore` (protocol primitives, cryptography, single-relay
transport), `NostrClient` (the high-level actor-based client), and `NostrWalletConnect` (NIP-47
wallet payments) — each with a matching test target under `Tests/`.

## Code formatting

The project uses [swift-format](https://github.com/swiftlang/swift-format) (bundled with the
Swift toolchain). The configuration lives in [`.swift-format`](.swift-format) and is enforced
by CI, so run it before pushing:

```bash
# Format in place
swift format --in-place --recursive --parallel Sources Tests Package.swift

# Check without modifying (what CI runs)
swift format lint --strict --recursive --parallel Sources Tests Package.swift
```

## Tests

Tests use [swift-testing](https://developer.apple.com/documentation/testing) (`@Suite`, `@Test`,
`#expect`) — not XCTest. Please follow the existing conventions:

- Every behavior change needs test coverage in the matching test target.
- Tests never touch the network. Relay behavior is driven through the in-memory mock transports
  in `Tests/NostrClientTests/Support/` (`MockWebSocketSession`, `MockURLSession`); use them
  instead of live relays or timing-dependent sleeps.
- Keep tests deterministic — prefer bounded polling helpers over fixed sleeps.

Run the whole suite with `swift test`, or a single suite with
`swift test --filter "Suite Name"`.

## Documentation

- Public symbols carry `///` documentation comments; new public API should too.
- Each library has a DocC catalog (`Sources/<Target>/<Target>.docc/`) with Getting Started and
  Advanced Usage articles. Update them when the public API changes.
- Build the combined documentation site locally with `./Scripts/build-docs.sh ./docs` (requires
  the `docc` tool from the Swift toolchain).
- If a change affects the public API surface, keep `llms.txt` / `llms-full.txt` (the
  LLM-oriented summaries at the repository root) in sync.

## Commits and pull requests

- Commit messages and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `ci:`, `chore:` — with an optional scope
  (e.g. `fix(nip19): …`) and `!` for breaking changes.
- Keep PRs small and focused on a single concern; describe the motivation in the PR body.
- CI must pass. The `Test` workflow lints formatting, builds and tests on Linux and macOS
  (with code coverage), compiles the libraries for iOS/tvOS/watchOS/visionOS, and builds for
  Android; the documentation build must also succeed for changes to DocC catalogs.
- New NIP implementations should link the relevant [NIP specification](https://github.com/nostr-protocol/nips)
  from the code or the PR description.

## Reporting issues

Use the [issue templates](https://github.com/yysskk/swift-nostr/issues/new/choose) for bug
reports, feature requests, and questions. For security vulnerabilities, do **not** open a public
issue — see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
