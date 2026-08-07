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

Out of scope — these are documented non-goals, not oversights. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md):

- Attacks requiring code execution as the user on an unlocked machine.
- Compromise of a device that already holds the content key.
- Traffic analysis over plain HTTP (request timing, counts, and sizes). Deploy behind TLS to close this.
- Denial of service against a self-hosted instance.
- Secure erasure guarantees on SSD or copy-on-write filesystems.
- Loss of both the recovery mnemonic and every device. This is unrecoverable by design.

## Design

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — key hierarchy, encryption, transport, recovery.
- [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) — adversaries, guarantees, explicit non-goals.
- [docs/DECISIONS.md](docs/DECISIONS.md) — what was rejected and why.
- `spec/` — the wire and crypto specification, plus conformance vectors every client must reproduce.

Claims in the README and these documents are verified against the code before each release. If you find a claim that the code does not support, report it as a vulnerability.

## Cryptography

No custom primitives. AES-256-GCM, HKDF-SHA256, HMAC-SHA256, and Argon2id, taken from platform crypto where available.

The server has two direct dependencies, twelve runtime crates. Client dependencies are limited to platform frameworks plus a vendored Argon2 reference implementation whose source hash is verified in CI.
