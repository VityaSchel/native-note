# Conformance vectors

A client is conformant when it reproduces every case here. Commands: [CONTRIBUTING.md](../CONTRIBUTING.md#conformance-vectors).

```
vectors/     the vectors themselves, committed
generator/   Rust tool that produces and verifies them
wordlists/   BIP39 wordlists, pinned by hash
```

## Reading a vector file

Each file is `{ "$generated": ..., "description": ..., "cases": [ ... ] }`, and each case has a `name`. Each case carries every input it needs, except that the exchanges in `sync.json` and `recovery.json` run in order against one server. The files are generated; never hand-edit them.

All binary is lowercase hex.

Boolean fields are assertions: `opens`, `decodes`, `pads`, `unpads`, `roundTrips`, `matches` (the rejection is the one named in `error`) and `opensUnderWrongVersion` (always `false`). A `false` `opens`, `decodes`, `pads`, `unpads` or `opensUnderWrongVersion` MUST be rejected.

`error` names the first failure, reading fields in order. A count larger than the input can hold fails only when an item runs out of input, so an earlier item's own failure comes first.

| `error`               | Meaning                                                                                                                                 |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `Truncated`           | The input ends inside a field or before a count's items                                                                                 |
| `TrailingBytes`       | Bytes remain after the message, or a non-zero byte in content's fill                                                                    |
| `UnknownDiscriminant` | A `version`, `kind`, `action` or `status` byte the position does not allow                                                              |
| `NotCanonical`        | A boolean other than `0x00` or `0x01`, invalid UTF-8, or content whose length is not the smallest multiple of 4096 B holding its fields |

A case whose name starts with `reject` is a negative test.

## Files

| File            | Covers                                                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `hkdf.json`     | Every `info` label in the protocol; `salt` is `null` for none. For `localDbKey`, concatenate `argonOut` and `machineId` into `ikm`; `localDbKeyWithoutMachineId` is `argonOut` alone |
| `blinding.json` | `blindingKey` from the Content key, then `blindedId`                                                                                                                                 |
| `content.json`  | Note and tombstone content with its fill                                                                                                                                             |
| `note.json`     | Sealed note payloads. `plaintext` is the encoded content; `aad` is the binding                                                                                                       |
| `frames.json`   | Every request and response frame                                                                                                                                                     |
| `envelope.json` | Sealed request and response envelopes                                                                                                                                                |
| `padding.json`  | Envelope padding buckets                                                                                                                                                             |
| `argon2.json`   | Argon2id at `m=1024, t=1, p=1`, with an NFD password also given as `passwordUtf8`; production parameters: [clients/DESIGN.md](../clients/DESIGN.md#unlock-parameters)                |
| `mnemonic.json` | The Recovery key's 24 words                                                                                                                                                          |
| `recovery.json` | `contentKeyEncrypted`, then `get` and `put` exchanges over the reference server semantics                                                                                            |
| `sync.json`     | End-to-end sync over the reference server semantics                                                                                                                                  |
| `export.json`   | Passphrase-encrypted exports at low-cost parameters                                                                                                                                  |
| `markdown.json` | One exported note file per case                                                                                                                                                      |

## Notes on specific files

**`mnemonic.json`** pins `wordlists/english.txt`, the BIP39 English list byte for byte as [bitcoin/bips](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt) publishes it, by SHA-256; verify the hash before decoding, since another list still yields valid-looking words.

**`content.json` and `frames.json`**: every `reject` case maps to a rejection rule in [docs/PROTOCOL.md](../docs/PROTOCOL.md).

**`content.json` and `note.json`**: `prefixUuid` asserts the UUID a client reads from the `version ‖ kind ‖ uuid` prefix of content it cannot decode; in `note.json` it re-derives `blindedId`, so the client reports the change as written by a newer version.

**`frames.json`** marks each case's `direction`, `request` or `response`: the decoder it goes through. An error response names its `reason`; `errorUnknownReason` decodes, and its `reason` is `fault`, the one a client reads an unknown byte as.

**`envelope.json`**'s `errorFor*` cases carry a request `frame` that opens but fails to unpad or decode, and the server's `response` to it: `responseInner` padded and sealed under `responseNonce`, with the frame's nonce as AAD, and its `reason`.

**`sync.json`**: a request's write order is the client's choice, and a step's `writes` come in the order its `request` carries them.

**`recovery.json`** exchanges name the `device` that sends them. A `put` carries the `recoveryKey`, `contentKey` and `nonce` that seal its blob; a `get` that returns a blob carries the `recoveryKey` the client holds and whether the blob `opens` under it.

**`markdown.json`** cases hold in both directions: rendering `uuid`, `createdAt`, `updatedAt` and `body` gives `markdown` byte for byte, and parsing `markdown` gives them back.

**`export.json`**'s `export` case lists the `entries` its `zip` holds, each a `name` and its `markdown` file. Sealing `zip` gives `file`, and reading `zip` gives `entries`; a writer's own zip of those entries need not match `zip` byte for byte. `rejectNewerVersion`'s `outcome`, `newerVersion`, asserts that a file starting with `NNEXPORT` and then any byte but `1` is refused as written by a newer version, never read as a zip.
