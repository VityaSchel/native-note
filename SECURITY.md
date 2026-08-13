# Security

## Reporting a vulnerability

Email a PGP-encrypted message to **hi@hloth.dev** with the email's [PGP key](https://hloth.dev/pgp) or send an encrypted message over Matrix to [@hloth:hloth.dev](https://matrix.to/#/@hloth:hloth.dev). Do not open a public issue.

Include what you need to make the problem reproducible: affected component and version, steps, and impact. A proof of concept helps but is not required to report.

Expect an acknowledgement within 7 days and an assessment within 30. Fixes ship as soon as they are ready; you will be credited unless you ask otherwise.

There is no bug bounty. This is a personal project.

## Scope

In scope:

- Anything that lets the server, a network observer, or a stolen disk read note content.
- Anything that lets an unauthorized party write to or delete from the server.
- Key derivation, key storage, and the recovery flow.
- Memory-safety or parsing faults in the server's request path.
- Data loss or corruption under crash, power loss, or concurrent writes.

Out of scope: the documented non-goals in [docs/ARCHITECTURE.md § Threat model](docs/ARCHITECTURE.md#threat-model). They are boundaries, not oversights.

## Design

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — key hierarchy, encryption, transport, recovery.
- [docs/ARCHITECTURE.md § Threat model](docs/ARCHITECTURE.md#threat-model) — adversaries, guarantees, explicit non-goals.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — keys, note encryption, transport, recovery.
- [spec/README.md](spec/README.md) — conformance vectors every client must reproduce.

Claims in the README and these documents are verified against the code before each release. If you find a claim that the code does not support, report it as a vulnerability.

## Cryptography

No custom primitives. AES-256-GCM, HKDF-SHA256, HMAC-SHA256, and Argon2id, taken from platform crypto where available.

The server has two direct dependencies, twelve runtime crates. Client dependencies are limited to platform frameworks plus Argon2 and SQLCipher, neither copied into this repository — `Package.resolved` pins both to commit revisions, and SQLCipher's framework additionally by SHA-256.
