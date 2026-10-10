# Native Note Sync Protocol

## Keys

| Key                           | Description                                                                                                                              | If lost or leaked                             |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| [API key](#api-key)           | Allows to write and delete encrypted notes on the server                                                                                 | Generate new one, re-login on all devices     |
| [Content key](#content-key)   | The main end-to-end encryption key for notes stored on the server, used by all clients, stored on the server encrypted with Recovery key | Re-encrypt all notes, re-login on all devices |
| [Recovery key](#recovery-key) | Decrypts Content key downloaded from server, allows to recover access without rotating Content key                                       | Generate new one and backup it                |

### API key

Authorizes API requests to the server. 32 secure random bytes generated during server setup (server-side). Serialized as lowercase 64-characters hex string with leading/trailing whitespaces trimmed.

### Content key

Encrypts note content for storage and sync via the server. Identical on every device, stored inside the encrypted local DB. 32 secure random bytes generated during server setup (client-side).

Stored on the server in encrypted form to allow recovery. Server never learns it, only stores encrypted with Recovery key.

### Recovery key

Encrypts Content key to store securely on the server.

32 secure random bytes generated during server setup (client-side). Serialized as 24 BIP39 words.

```
contentKeyEncrypted = AES-256-GCM(recoveryKey, e2eeContentKey)
```

Clients never persist the recovery key, user is responsible for storing it securely. A client puts the blob at its pinned `v + 1`, never at a fetched `v + 1`. The pin is the `v` of the last blob the client put or opened, 0 before either.

## Notes

Clients render the first line of `body` as the title.

Note store request, visible to the server:

- `blindedId` — [note's UUID](./ARCHITECTURE.md#notes) is blinded with Content key-derived `blindingKey`. HMAC-SHA256 truncated to its first 16 bytes (RFC 4868's standard `HMAC-SHA-256-128`), same width as the UUID.

```
blindingKey = HKDF-SHA256(e2eeContentKey, info: "native-note/id-blind/v1", 32)
blindedId = HMAC-SHA256(blindingKey, uuid)[0..16]
```

- `v` — a `u32` starting at 1, plaintext because the server compares it. The server rejects a write unless `v == storedV + 1`, computed without wrapping: at `storedV = u32::MAX` every write is `conflict`. A client never computes `v + 1` past `u32::MAX`.
- `payload` — encrypted content. Encryption is per write, not per note. Payload encryption key is derived from Content key with a 128-bit salt random per write. Nonce is random.

```
writeId = 128-bit random salt, stored and transmitted in plaintext
noteKey = HKDF-SHA256(e2eeContentKey, salt: writeId, info: "native-note/note/v1", 32)
payload = AES-256-GCM(noteKey, content, aad: blindedId ‖ v_be32 ‖ writeId)
```

Content is the binary layout below.

### Content

End-to-end encrypted with the Content key, opaque to the server. Fixed binary layout, big-endian:

```
version(1) = 0x01
kind(1)
  0x01 note        uuid(16) ‖ createdAt_be64 ‖ updatedAt_be64 ‖ bodyLen_be32 ‖ body
  0x02 tombstone   uuid(16) ‖ deletedAt_be64
```

Timestamps are epoch milliseconds as signed 64-bit. `body` is UTF-8. An unknown `version` or `kind` is rejected.

Deleting a note writes a tombstone. Tombstones are not garbage-collected.

## Binary encoding

Everything inside the envelope is fixed-layout binary.

Rules, applied uniformly so that every message has exactly one valid encoding:

- Integers are unsigned big-endian at their stated width, except timestamps which are signed.
- Variable-length fields are `len_be32 ‖ bytes`. Arrays are `count_be32 ‖ item*`.
- Booleans are `0x00` or `0x01`. Any other value is rejected.
- Enum discriminants are one byte. Unknown values are rejected.
- A message must consume its buffer exactly. Trailing bytes are rejected.

Decoders must be total: bounds-check every read, never allocate from a length or count before it has been checked against the remaining input, and return an error rather than panicking.

## Ordering

The server assigns a monotonic `seq` to every accepted write; clients pull `since=seq`. It is an application counter the server maintains, incremented inside the same transaction as the write it stamps, strictly increasing, never reused, and never reassigned to an earlier value. Clients echo it back as-is. List ordering and date grouping are computed locally by `updatedAt`.

## Transport

Authentication is proved by sealing the envelope. Metadata is encrypted, not just content, so a reverse proxy sees only the sealed envelope. No device IDs so an observer can't tell which device has sent request and how many of them there are. No certificates, no domain name, no TLS required.

A replayed write is rejected by `v == storedV + 1`, since the server has already advanced. A replayed pull returns a response sealed to a key the attacker does not hold.

```
envelopeKey = HKDF-SHA256(apiKey, info: "native-note/envelope/v1", 32)

request  = nonce ‖ ciphertext ‖ tag    # AES-256-GCM(envelopeKey, padded, aad: empty)
response = nonce ‖ ciphertext ‖ tag    # AES-256-GCM(envelopeKey, padded, aad: requestNonce)
```

The envelope has no version byte; [its label](#hkdf-label-registry) versions it.

### Padding

`padded = len_be32 ‖ inner ‖ zero fill` to the next bucket. Buckets double from 256 B up to the body limit, measured on `padded`, which is the sealed length minus 28 B in both directions. Both directions pad before sealing, so neither request nor response length leaks more than a bucket.

## API

`POST /` is the only route; any other method or path is `400`.

Distinct HTTP status codes exist only for outcomes with no sealed response and carry no application meaning: `400` malformed or unopenable, `413` oversize, `500` a fault that leaves no sealed response. No meaningful `409`/`404`/`401`.

### `POST /` — call

Binary frame — sealed envelope, parsed after GCM verification. Every sealed response is HTTP 200, and every outcome is a field inside it.

Every action is sealed under `envelopeKey`. There is no server-side device enrollment or sessions management.

Each action is one byte; every response except `error` echoes it.

| `action` | Byte | Purpose                               |
| -------- | ---- | ------------------------------------- |
| `sync`   | 0x01 | Push writes, pull since `seq`         |
| `get`    | 0x02 | Read `contentKeyEncrypted`            |
| `put`    | 0x03 | Store or rotate `contentKeyEncrypted` |

#### Action `sync`

```
request    0x01 ‖ since_be64 ‖ writeCount_be32 ‖ write*
write      blindedId(16) ‖ v_be32 ‖ writeId(16) ‖ payloadLen_be32 ‖ payload

response   0x01 ‖ resultCount_be32 ‖ result*
                ‖ changeCount_be32 ‖ change*
                ‖ nextSeq_be64 ‖ more(1)
result     status(1) ‖ v_be32 ‖ seq_be64
change     same layout as write
```

`results` carries one entry per submitted write, in the order submitted; a client treats a response with any other count as an error. **`v` and `seq` must be echoed** — without them the client cannot advance and every later write conflicts.

| `status`    | Byte | Description                                            |
| ----------- | ---- | ------------------------------------------------------ |
| `accepted`  | 0x01 | Stored. `v` and `seq` are the values now on the server |
| `conflict`  | 0x02 | `v != storedV + 1`                                     |
| `too_large` | 0x03 | Payload over the [note limit](#limits)                 |

A write that fails both checks gets `too_large`.

On every status except `accepted`, `v` is the server's current version and `seq` is `0`; a non-zero `seq` alongside another status is rejected.

The server applies a `sync`'s writes before it reads `changes`, so accepted writes come back in the same response. A `sync` is applied atomically: after `error` none of its writes are stored, so a retry is safe.

A response that sets `more` carries at least one change, and the client pulls again from `nextSeq`. Clients batch writes so each request stays within the body limit, and never send a payload over the note limit.

#### Actions `get` and `put`

```
get request    0x02
get response   0x02 ‖ v_be32 ‖ blobLen_be32 ‖ blob

put request    0x03 ‖ v_be32 ‖ blobLen_be32 ‖ blob
put response   0x03 ‖ status(1) ‖ v_be32
```

With no blob stored, `get` returns `v = 0` and an empty blob.

A `put` follows the same [version rule](#notes) as notes and answers `accepted` or `conflict` with the server's current `v`; any other status in a `put` response is rejected. On `conflict` the client gets the blob. If it opens under the Recovery key the client just put, that `put` landed; otherwise [Recovery flow](../clients/DESIGN.md#recovery-flow) handles it.

#### Response `error`

```
error response   0xff
```

A request that unseals but fails to unpad or decode, or hits a fault after unsealing, a full disk included, gets `error`.

## HKDF label registry

Every `info` label in the protocol, in one place. New labels must not collide; a changed derivation bumps its `/v`, and a changed envelope layout bumps `native-note/envelope/v1`.

| Label                                          | Derives             | From                   |
| ---------------------------------------------- | ------------------- | ---------------------- |
| `native-note/envelope/v1`                      | `envelopeKey`       | API key                |
| `native-note/id-blind/v1`                      | `blindingKey`       | Content key            |
| `native-note/note/v1`                          | `noteKey` per write | Content key            |
| `native-note/localdb/v1`                       | `localDbKey`        | `argonOut ‖ machineId` |
| `native-note/machine-id/v1`                    | `machineId`         | hardware agreement     |

## Limits

| Limit                                  | Maximum | Exceeded                                                       |
| -------------------------------------- | ------- | -------------------------------------------------------------- |
| Note payload                           | 1 MiB   | `too_large` in the response                                    |
| Body, measured on [`padded`](#padding) | 2 MiB   | Request: HTTP `413`. Response: `changes` truncated, `more` set |
