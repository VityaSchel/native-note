# Native Note Architecture

## Cryptography

- **AEAD:** AES-256-GCM, for hardware acceleration and Android Keystore support
  - Not XChaCha20-Poly1305: not native on any platform; CryptoKit's `ChaChaPoly` and Android's `ChaCha20/Poly1305` are the 96-bit-nonce IETF variant
  - Not IETF ChaCha20-Poly1305: less hardware acceleration, absent from Android Keystore
- **Key derivation:** HKDF-SHA256 (RFC 5869)
- **MAC and ID blinding:** HMAC-SHA256
- **Password KDF:** Argon2id, client only
  - Not PBKDF2: GPU-crackable without a secure enclave
- **Hardware binding:** platform-specific
- **Protocol format:** fixed-layout binary, one valid encoding per message
  - Not JSON: base64 is ~133% of binary and needs a parser
  - Not CBOR or MessagePack: not native
- **Transport envelope:** HKDF-SHA256 into AES-256-GCM
  - Not JWE: JOSE's algorithm-agility pitfalls, plus base64
  - Not libsodium `secretbox`: not native anywhere
  - Not HPKE PSK mode: Android ships Base mode only
- **Note keys:** a per-write key from a random `writeId`, plus a random nonce
  - Not a counter nonce: two offline devices can both write `v = 5` to one note, and a repeated GCM nonce is catastrophic
  - Not one key for every note: a key per write rules out nonce reuse and binds the key to its write

All keys are 256-bit. Nonces are random 96-bit.

## Components

| Component                                  | Stack                        |
| ------------------------------------------ | ---------------------------- |
| [Server](../server/DESIGN.md)              | Rust 1.95+                   |
| [macOS client](../clients/macos/README.md) | Swift 6.2+, SwiftUI + AppKit |

No shared core. Each client implements [clients/DESIGN.md](../clients/DESIGN.md) and must pass the [conformance vectors](../spec/README.md).

## Storage

Offline-first. Notes are encrypted at rest under a mandatory unlock password; a sync server is optional.

### Notes

- ID: a client-generated UUIDv4
- Created At, Updated At
- Body: plain text, rendered as markdown; the first line is the title

### Exports

A zip of markdown files, one per live note, with metadata in front matter, optionally encrypted whole under a passphrase rather than with zip's own encryption, which leaves file names readable.

## Threat model

| Actor                         | Trust                                                                                      |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| Unlocked device, user present | Trusted                                                                                    |
| Locked or powered-off device  | Untrusted, must reveal nothing about notes content                                         |
| Sync server                   | Untrusted for confidentiality, only trusted to store blobs and enforce the version counter |
| Reverse proxy                 | Untrusted, sees sealed envelopes only                                                      |
| Network                       | Untrusted, sees sealed envelopes only                                                      |

[ThreatModelCoverageTests](../clients/macos/native-note-kit/Tests/NativeNoteKitTests/ThreatModel/ThreatModelCoverageTests.swift) maps every row and entry in this section, non-goals included, to the tests that prove it.

Known limitations, out of scope:

- Code execution as the user on an unlocked machine — the content key is in memory
- Compromise of a device holding the content key
- Traffic analysis over plain HTTP — timing, counts, request size
- Malicious server withholding notes — until the [authenticated manifest](./ROADMAP.md)
- Secure erasure of deleted content — not achievable on SSD or copy-on-write storage
- Loss of the mnemonic and every device
- Denial of service
- Coercion

Documented risks and vulnerabilities:

- **No forward secrecy for metadata.** A leaked `apiKey` retroactively decrypts captured envelopes, except those that also crossed TLS.
- **Argon2 and SQLCipher** are third-party C in the client, built from pinned source.
- **Hand-rolled HTTP parser.** Constrained grammar, fuzzed; a reverse proxy is recommended for public deployments.
- **Plaintext `v` leaks per-note edit counts.** Encrypting it would stop the server enforcing the version rule.
- **Payload length leaks note size in 4 KiB steps.** [Content](./PROTOCOL.md#content) is zero-filled to a multiple of 4096 B, so the server and its backups see how many blocks each version takes, but not which writes delete or how long a short note is.
- **An API-key holder can destroy the recovery path.** Overwriting `contentKeyEncrypted` needs neither the Recovery key nor the Content key. A planted blob fails the tag on decrypt, so they can only make recovery unusable.
- **Server data-directory compromise leaks the API key.** Reading `/var/lib/native-note-server/api-key` decrypts metadata and forges writes.
- **No per-device revocation.** Losing a device means [replacing the API key](guides/setup-sync-server.md#connect-a-client) and entering it on the rest.
- **A short password or pin without hardware binding** is brute-forceable offline in hours.
- **No in-app unlock attempt limiting.** A counter would sit in storage the attacker owns, and an attacker goes after the database file, not the app. Erasing a library with a forgotten password needs only a confirmation; anyone in an unlocked session can delete its folder anyway.
- **Hardware binding does not add per-guess cost.** A disk image alone cannot be attacked offline at all, but code running on the machine reads `machineId` with one call and then guesses offline at Argon2id cost.
- **The content key never rotates.** The recovery layer spares re-encrypting every note when the mnemonic leaks, but a leaked mnemonic still opens any older copy of the recovery blob, such as a server backup, and with it every note.
