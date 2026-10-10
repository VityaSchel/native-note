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

Each file is `{ "$generated": ..., "description": ..., "cases": [ ... ] }`, and each case has a `name`. Each case carries every input it needs, except that the exchanges in `sync.json` and `recovery.json` run in order against one server.

**These files are generated and must not be hand-edited.** CI regenerates and fails on any difference, a protocol change shows up as a reviewable vector diff, and a client can run its conformance tests without a Rust toolchain.

All binary is lowercase hex.

A boolean field is an **assertion the implementation must satisfy**, not data to copy:

| Field                    | Meaning                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| `opens`                  | Whether the input is accepted and decrypts. `false` means it MUST be rejected |
| `decodes`                | Whether the input parses. `false` means it MUST be rejected                   |
| `pads`                   | Whether padding succeeds. `false` means it MUST be rejected                   |
| `unpads`                 | Whether unpadding succeeds. `false` means it MUST be rejected                 |
| `roundTrips`             | Encoding then decoding returns the original                                   |
| `matches`                | The rejection produced the specific error named in `error`                    |
| `opensUnderWrongVersion` | Whether the payload decrypts at `v + 1`. Always `false`: it MUST be rejected  |

`error` names the first failure, reading fields in order. A count larger than the input can hold fails only when an item runs out of input, so an earlier item's own failure comes first:

| `error`               | Meaning                                                                                            |
| --------------------- | -------------------------------------------------------------------------------------------------- |
| `Truncated`           | The input ends inside a field or before a count's items                                            |
| `TrailingBytes`       | Bytes remain after the message                                                                     |
| `UnknownDiscriminant` | A `version`, `kind`, `action` or `status` byte the position does not allow                         |
| `NotCanonical`        | A boolean other than `0x00` or `0x01`, invalid UTF-8, or a non-zero `seq` on a non-accepted result |

Every case whose name starts with `reject` is a negative test. Passing them matters as much as the positive cases — most of them exist because a plausible implementation would silently accept the input.

## Files

| File            | Covers                                                                                                                                                                                                                                 |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hkdf.json`     | Every `info` label in the protocol, with `ikm`, `salt` (`null` for none), `length` and expected `okm`. For `localDbKey`, concatenate `argonOut` and `machineId` into `ikm`; `localDbKeyWithoutMachineId` is `argonOut` alone           |
| `blinding.json` | `blindingKey` from the Content key, then `blindedId` for a UUID and for one a single bit apart                                                                                                                                         |
| `content.json`  | Note and tombstone encoding, pre-epoch timestamps, a non-v4 UUID with reversed timestamps, plus unknown version, unknown kind, trailing bytes, truncation, impossible length, and invalid, overlong, surrogate and out-of-range UTF-8  |
| `note.json`     | Sealed note payloads. `plaintext` is the encoded content; `aad` is the binding                                                                                                                                                         |
| `frames.json`   | Every request and response shape and status byte, plus unknown action and status, `too_large` on a put, non-canonical bool, impossible count and length, a bad item before a short count, trailing bytes, seq on a non-accepted result |
| `envelope.json` | Request and response frames, plus wrong request nonce, truncation, a request replayed as a response, a response replayed as a request, and the reference server's sealed `error` for a request that fails to unpad or decode           |
| `padding.json`  | Bucket boundaries either side of 256, 512 and 1024, the largest bucket at 2 MiB and one byte past it, plus non-bucket length, a larger bucket than needed, a length past the end, and dirty fill                                       |
| `argon2.json`   | Argon2id at fixed low-cost parameters, including an unnormalized (NFD) password given also as `passwordUtf8`                                                                                                                           |
| `mnemonic.json` | Wordlist identity, 24-word round-trip, bad checksum, wrong word count, unknown word                                                                                                                                                    |
| `recovery.json` | `contentKeyEncrypted`, a wrong Recovery key and a wrong plaintext length, then `get` and `put` exchanges over the reference server semantics: setup with a lost response, a join, a rotation, and a stale pin                          |
| `sync.json`     | Seven-step end-to-end scenario over the reference server semantics                                                                                                                                                                     |
| `export.json`   | Passphrase-encrypted export of a one-note zip at low-cost parameters, plus wrong passphrase, flipped salt and ciphertext bytes, truncated tag, unknown magic, and each Argon2id parameter bound                                        |
| `markdown.json` | One exported note file per case, including a pre-epoch time, years outside 0000–9999 and beyond six digits, and a body with CR                                                                                                         |

## Notes on specific files

**`mnemonic.json`** pins the wordlist by the SHA-256 of `wordlists/english.txt`, the BIP39 English list byte for byte as [bitcoin/bips](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt) publishes it: 2048 lines, each ending in LF. Substituting a different list would still produce 24 valid-looking words that decode to different entropy — silently, and only discovered when a recovery fails. Verify the hash before trusting a decode. The encoding is BIP39's word mapping and checksum only; **BIP39 seed derivation is never used**.

**`argon2.json`** uses `m=1024, t=1, p=1` so CI stays fast. Production parameters are calibrated per device and stored in the unlock parameter file — see [`clients/DESIGN.md`](../clients/DESIGN.md#unlock-parameters). This vector exists to confirm you are calling Argon2**id** as [`clients/DESIGN.md`](../clients/DESIGN.md#local-db-encryption) specifies, nothing more.

**`content.json` and `frames.json`** carry most of the negative cases, because the binary decoder is the only attacker-reachable parser after GCM verification. Every `reject` case there corresponds to a rejection rule in [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

**`frames.json`** marks each case's `direction`, `request` or `response`: the decoder it goes through.

**`envelope.json`**'s `errorFor*` cases carry a request `frame` that opens but fails to unpad or decode, and the server's `response` to it: `responseInner` padded and sealed under `responseNonce`, with the frame's nonce as AAD.

**`sync.json`** exercises protocol semantics rather than framing — the version rule, `seq` assignment, conflict reporting, the losing edit kept as a new note, tombstones, and writes applied in the order submitted. Each step carries the encoded `request` and `response` a client would seal, with a readable `outcome` alongside, and the Content key and each write's content, `writeId` and nonce. A request's write order is the client's choice, and a step's `writes` come in the order its `request` carries them. Step 2 carries the conflict copy's `copyUuid`. A step whose `device` is `null` is no client's: it `replays` an earlier step's request bytes. Envelope framing is covered by `envelope.json`; the two compose.

Step 2 is the case worth implementing against first: two devices produce `v = 1` for the same note while offline, and the second is rejected with the server's current `v` rather than overwriting.

**`recovery.json`** exchanges name the `device` that sends them. A `put` carries the `recoveryKey`, `contentKey` and `nonce` that seal its blob; a `get` that returns a blob carries the `recoveryKey` the client holds and whether the blob `opens` under it.

**`markdown.json`** cases hold in both directions: rendering `uuid`, `createdAt`, `updatedAt`, `v` and `body` gives `markdown` byte for byte, and parsing `markdown` gives them back.

**`export.json`**'s `export` case lists the `entries` its `zip` holds, each a `name` and its `markdown` file. Sealing `zip` gives `file`, and reading `zip` gives `entries`; a writer's own zip of those entries need not match `zip` byte for byte.

## Adding a vector

Add the case to the generator, run `cargo run --bin gen-vectors`, and commit the regenerated JSON in the same commit as the spec change that motivated it. `cargo test` will fail if the committed file and the generator disagree, and separately if a `.json` appears in `vectors/` that the generator does not produce.
