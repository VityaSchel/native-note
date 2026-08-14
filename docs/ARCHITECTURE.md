# Native Note Architecture

## Cryptography

- **AEAD:** AES-256-GCM
  - More hardware-acceleration support, available in Android Keystore
  - Not XChaCha20-Poly1305: not available natively, CryptoKit's `ChaChaPoly` and Android's `ChaCha20/Poly1305` are both the 96-bit-nonce IETF variant
  - Not IETF ChaCha20-Poly1305: less hardware acceleration support, not available in Android Keystore
- **Password KDF**: Argon2id, client only
  - Not PBKDF2: Crackable on GPUs for users without secure enclave
- **Protocol format:** fixed-layout binary
  - Not JSON: base64 is ~133% of binary and needs a parser
  - Not CBOR or MessagePack: not natively available
  - Fixed layout removes canonicalization as a rule to follow
- **Transport envelope:** HKDF-SHA256 (RFC 5869) into AES-256-GCM, `nonce ‖ ciphertext ‖ tag`
  - Not JWE: JOSE's algorithm-agility pitfalls, on top of the base64 cost
  - Not libsodium `secretbox`: not platform-native anywhere
  - Not HPKE PSK mode: absent on Android, which ships Base mode only
- **Note nonce:** Per-write key from random `writeId`, plus random nonce
  - Not a counter-based nonce: two devices offline can both produce `v=5` for one note, so counters collide and GCM breaks catastrophically
  - Not a single key for all notes: a random `writeId` per write makes reuse structurally impossible, and binds the key to that one write

## Components

| Component                                  | Stack                        |
| ------------------------------------------ | ---------------------------- |
| [Server](../server/DESIGN.md)              | Rust 1.95+                   |
| [macOS client](../clients/macos/README.md) | Swift 6.2+, SwiftUI + AppKit |

No shared core. Each client implements [clients/DESIGN.md](../clients/DESIGN.md) and must pass the [conformance vectors](../spec/README.md).

## Primitives

| Purpose          | Primitive         |
| ---------------- | ----------------- |
| AEAD             | AES-256-GCM       |
| Key → key        | HKDF-SHA256       |
| Password → key   | Argon2id          |
| MAC / blinding   | HMAC-SHA256       |
| Hardware binding | platform-specific |

All keys are 256-bit. Nonces are securely-random 96-bit.

## Storage

The app works offline-first and encrypts notes at rest using mandatory unlock password. A sync server can be optionally configured for E2EE storage of notes remotely and syncing across multiple devices.

### Notes

Note model:

- ID — a client-generated UUIDv4
- Created At — creation date
- Updated At — modification date
- Body — stored as plain text, formatted as markdown by clients; title is the first line

### Exports

Markdown files in a zip, one per note, metadata in front matter. Produces an unencrypted copy of everything, so the flow warns and offers passphrase encryption (separate from ZIP's native password protection, because it allows to list files in the archive).

## Threat model

| Actor                         | Trust                                                                                      |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| Unlocked device, user present | Trusted                                                                                    |
| Locked or powered-off device  | Untrusted, must reveal nothing about notes content                                         |
| Sync server                   | Untrusted for confidentiality, only trusted to store blobs and enforce the version counter |
| Reverse proxy                 | Untrusted, sees sealed envelopes only                                                      |
| Network                       | Untrusted, sees sealed envelopes only                                                      |

Known limitations, out of scope:

- Code execution as the user on an unlocked machine — the content key is in memory
- Compromise of a device holding the content key
- Traffic analysis over plain HTTP — timing, counts, request size
- Malicious server withholding, against a restoring client — restoring from scratch has nothing to compare against
- Secure erasure of deleted content — not achievable on SSD or copy-on-write storage
- Loss of the mnemonic and every device
- Denial of service
- Coercion

Documented risks and vulnerabilities:

- **No forward secrecy for metadata.** A leaked `apiKey` retroactively decrypts captured envelopes
- **Argon2 and SQLCipher** are third-party C in the client, pinned to commit revisions. SQLCipher is a prebuilt binary.
- **Hand-rolled HTTP parser.** Constrained grammar, fuzzed, reverse proxy recommended for public deployments.
- **Plaintext `v` leaks per-note edit counts.** Encrypting it would stop the server enforcing the version rule.
- **An API-key holder can destroy the recovery path.** Overwriting `contentKeyEncrypted` needs neither the Recovery key nor the Content key. They cannot substitute a key they control — a planted blob fails the tag on decrypt — only render recovery unusable.
- **Server data-directory compromise leaks the API key.** An attacker who reads `/var/lib/native-note-server/api-key` can decrypt metadata and forge writes.
- **No per-device revocation.** Losing a device means rotating the API key on the rest.
- **A short password or pin without hardware binding** is brute-forceable offline in hours.
- **In-app unlock attempt limiting is not a security control.** The counter sits in storage the attacker owns, and a real attacker attacks the database file rather than the app. It is a panic feature — wipe after N — and friction, nothing more.
- **Hardware binding does not add per-guess cost.** A disk image cannot compute `machineId` at any password length, so it cannot be attacked offline at all. An attacker who runs code on the machine reads `machineId` with one call and then guesses offline at Argon2id cost.
- **The content key never rotates.** The recovery layer exists so a leaked mnemonic does not require entire database re-encryption.
