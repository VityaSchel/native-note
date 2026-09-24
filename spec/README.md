# Conformance vectors

Conformance vectors keep clients implementations of protocol identical. A client is conformant when it reproduces every case here.

```
vectors/     the vectors themselves, committed
generator/   Rust tool that produces and verifies them
wordlists/   BIP39 wordlists, pinned by hash
```

```sh
cd generator
cargo test                    # generator reproduces every committed vector
cargo run --bin gen-vectors   # regenerate after an intentional protocol change
```

The generator is deterministic, enforced by CI. A spec change is not done until the vectors are regenerated in the same commit.

## Reading a vector file

Each file is `{ "$generated": ..., "description": ..., "cases": [ ... ] }`, and each case has a `name`.

**These files are generated and must not be hand-edited.** CI regenerates and fails on any difference, a protocol change shows up as a reviewable vector diff, and a client can run its conformance tests without a Rust toolchain.

All binary is lowercase hex.

A boolean field is an **assertion the implementation must satisfy**, not data to copy:

| Field                    | Meaning                                                                                 |
| ------------------------ | --------------------------------------------------------------------------------------- |
| `opens`                  | Whether the frame decrypts. `false` means it MUST be rejected                           |
| `decodes`                | Whether the input parses. `false` means it MUST be rejected                             |
| `unpads`                 | Whether unpadding succeeds. `false` means it MUST be rejected                           |
| `roundTrips`             | Encoding then decoding returns the original                                             |
| `splits`                 | The credential parses back into exactly its two keys. `false` means it MUST be rejected |
| `matches`                | The rejection produced the specific error named in `error`                              |
| `opensUnderWrongVersion` | Whether the payload decrypts at `v + 1`. Always `false`: it MUST be rejected            |

Every case whose name starts with `reject` is a negative test. Passing them matters as much as the positive cases — most of them exist because a plausible implementation would silently accept the input.

## Files

| File            | Covers                                                                                                                                                               |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hkdf.json`     | Every `info` label in the protocol, with `ikm`, `salt`, `length` and expected `okm`                                                                                  |
| `blinding.json` | `blindingKey` from the Content key, then `blindedId` for a UUID and for one a single bit apart                                                                       |
| `content.json`  | Note and tombstone encoding, plus unknown version, unknown kind, trailing bytes, truncation, invalid UTF-8                                                           |
| `note.json`     | Sealed note payloads. `plaintext` is the encoded content; `aad` is the binding                                                                                       |
| `frames.json`   | Every request and response shape and status byte, plus unknown action and status, non-canonical bool, impossible count, trailing bytes, seq on a non-accepted result |
| `envelope.json` | Request and response frames, plus flipped version, wrong request nonce, truncation, and a request replayed as a response                                             |
| `padding.json`  | Bucket boundaries either side of 256, 512 and 1024, plus non-bucket length and dirty fill                                                                            |
| `argon2.json`   | Argon2id at fixed low-cost parameters. Pins the algorithm, not the production cost                                                                                   |
| `mnemonic.json` | Wordlist identity, 24-word round-trip, bad checksum, wrong word count, unknown word                                                                                  |
| `pairing.json`  | The 64-byte pairing credential and its length rejections                                                                                                             |
| `sync.json`     | Six-step end-to-end scenario over the reference server semantics                                                                                                     |

## Notes on specific files

**`mnemonic.json`** pins the wordlist by SHA-256. Substituting a different list would still produce 24 valid-looking words that decode to different entropy — silently, and only discovered when a recovery fails. Verify the hash before trusting a decode. The encoding is BIP39's word mapping and checksum only; **BIP39 seed derivation is never used**.

**`argon2.json`** uses `m=1024, t=1, p=1` so CI stays fast. Production parameters are calibrated per device and stored in the unlock parameter file — see [`clients/DESIGN.md`](../clients/DESIGN.md#unlock-parameters). This vector exists to confirm you are calling Argon2**id** with the right version and output length, nothing more.

**`content.json` and `frames.json`** carry most of the negative cases, because the binary decoder is the only attacker-reachable parser after GCM verification. Every `reject` case there corresponds to a rule in [`docs/PROTOCOL.md` § Binary encoding](../docs/PROTOCOL.md#binary-encoding).

**`frames.json`** marks each case's `direction`, `request` or `response`: the decoder it goes through.

**`sync.json`** exercises protocol semantics rather than framing — the version rule, `seq` assignment, conflict reporting and tombstones. Each step carries the encoded `request` and `response` a client would seal, with a readable `outcome` alongside. Envelope framing is covered by `envelope.json`; the two compose.

Step 2 is the case worth implementing against first: two devices produce `v = 1` for the same note while offline, and the second is rejected with the server's current `v` rather than overwriting.

## Adding a vector

Add the case to the generator, run `cargo run --bin gen-vectors`, and commit the regenerated JSON in the same commit as the spec change that motivated it. `cargo test` will fail if the committed file and the generator disagree, and separately if a `.json` appears in `vectors/` that the generator does not produce.
