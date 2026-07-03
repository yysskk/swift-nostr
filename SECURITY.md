# Security Policy

## Supported versions

Security fixes are applied to the latest release line. Older releases do not receive patches;
please stay on the most recent version.

## Reporting a vulnerability

Please do **not** report security vulnerabilities through public GitHub issues, discussions,
or pull requests.

Instead, report them privately through
[GitHub's private vulnerability reporting](https://github.com/yysskk/swift-nostr/security/advisories/new)
("Report a vulnerability" on the repository's Security tab).

Include as much of the following as you can:

- A description of the vulnerability and its impact
- Steps to reproduce, or a proof-of-concept
- The affected version(s) or commit
- Any suggested remediation

Reports are triaged as quickly as possible. Please allow time for a fix and coordinated
disclosure before sharing details publicly.

## Scope

This library implements cryptographic protocols (Schnorr signatures, NIP-44 encryption, NIP-59
gift wrap, key derivation) and networked relay communication. Issues such as key or plaintext
leakage, signature or verification bypasses, encryption weaknesses, and malicious-relay input
handling are all in scope and appreciated.
