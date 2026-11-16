# Security

## Reporting a vulnerability

Email a PGP-encrypted message to **hi@hloth.dev** with the email's [PGP key](https://hloth.dev/pgp) or send an encrypted message over Matrix to [@hloth:hloth.dev](https://matrix.to/#/@hloth:hloth.dev). Do not open a public issue.

Include the affected component and version, steps to reproduce, and impact. A proof of concept is welcome, not required.

Expect an acknowledgement within 7 days and an assessment within 30. Fixes ship as soon as they are ready; you will be credited unless you ask otherwise.

There is no bug bounty. This is a personal project.

## Scope

In scope:

- Anything that lets the server, a network observer, or a stolen disk read note content.
- Anything that lets an unauthorized party write to or delete from the server.
- Key derivation, key storage, and the recovery flow.
- Memory-safety or parsing faults in the server's request path.
- Data loss or corruption under crash, power loss, or concurrent writes.

Out of scope: the non-goals in [docs/ARCHITECTURE.md § Threat model](docs/ARCHITECTURE.md#threat-model).

Claims in the README and the documents below are verified against the code before each release; report one the code does not support as a vulnerability.

## Design

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — primitives, components, threat model.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — keys, note encryption, transport, recovery.
- [clients/DESIGN.md](clients/DESIGN.md) — local encryption, unlock, recovery flow, sync.
- [spec/README.md](spec/README.md) — conformance vectors every client must reproduce.

## Cryptography

No custom primitives; platform crypto where available. Primitives: [docs/ARCHITECTURE.md § Cryptography](docs/ARCHITECTURE.md#cryptography). Dependencies: [server/DESIGN.md](server/DESIGN.md) and [clients/macos/README.md](clients/macos/README.md).
