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

Encrypts Content key to store securely on the server. 32 secure random bytes generated during server setup (client-side).

```
contentKeyEncrypted = AES-256-GCM(recoveryKey, e2eeContentKey)
```

Clients never persist the recovery key, user is responsible for storing it securely. Clients pin the last-seen `v` and report an unexpected advance to prevent racing overwrite.

## Notes

Note store request, visible to the server:

- `blindedId` — [note's UUID](./ARCHITECTURE.md#notes) is blinded with Content key-derived `blindingKey`. HMAC-SHA256 truncated to its first 16 bytes (RFC 4868's standard `HMAC-SHA-256-128`), same width as the UUID.

```
blindingKey = HKDF-SHA256(e2eeContentKey, info: "native-note/id-blind/v1", 32)
blindedId = HMAC-SHA256(blindingKey, uuid)[0..16]
```

- `v` — a `u32` starting at 1, plaintext because the server compares it. The server accepts a write if and only if `v == storedV + 1`. At `v == u32::MAX` the server rejects further writes to that note rather than wrapping.
- `deleted` — set to `true` to write tombstone instead of note content. Tombstones are not garbage-collected.
- `payload` — encrypted content. Encryption is per write, not per note. Payload encryption key is derived from Content key with a 128-bit salt random per write. Nonce is random.

```
writeId = 128-bit random salt, stored and transmitted in plaintext
noteKey = HKDF-SHA256(e2eeContentKey, salt: writeId, info: "native-note/note/v1", 32)
payload = AES-256-GCM(noteKey, content, aad: blindedId ‖ v_be32 ‖ writeId)
```

Content is canonical JSON.

### Content

End-to-end encrypted with Content key. Opaque to server. Fields:

- `uuid` — note's UUID

Additionally, for new note version only:

- `body` - note's content. There is no `title` field — clients render the first line of `body` as the title
- `createdAt` - date
- `updatedAt` - date

Additionally, for tombstone only:

- `deletedAt` — date

## Canonical encoding

Mandatory for every client, or deterministic vectors are impossible:

- Compact UTF-8 JSON, no insignificant whitespace.
- Keys sorted by Unicode code point.
- Absent optionals omitted, never `null`.
- Timestamps RFC 3339 with `Z`, no offsets.
- Binary values (`blindedId`, `writeId`, `payload`, `blob`) as standard base64 (RFC 4648 §4) with padding. Encoders emit canonical form; decoders reject anything else.
- `seq` is a JSON number and stays below 2^53 (unreachable in practice).

### Ordering

The server assigns a monotonic `seq` to every accepted write; clients pull `since=seq`. It is an application counter the server maintains, incremented inside the same transaction as the write it stamps, strictly increasing, never reused, and never reassigned to an earlier value. Clients echo it back as-is. List ordering and date grouping are computed locally by `updatedAt`.

## Transport

Authentication is proved by sealing the envelope. Metadata is encrypted, not just content, so a reverse proxy sees only the sealed envelope. No device IDs so an observer can't tell which device has sent request and how many of them there are. No certificates, no domain name, no TLS required.

A replayed write is rejected by `v == storedV + 1`, since the server has already advanced. A replayed pull returns a response sealed to a key the attacker does not hold.

```
envelopeKey = HKDF-SHA256(apiKey, info: "native-note/envelope/v1", 32)

request  = version ‖ nonce ‖ ciphertext ‖ tag    # AES-256-GCM(envelopeKey, padded, aad: version)
response =           nonce ‖ ciphertext ‖ tag    # AES-256-GCM(envelopeKey, padded, aad: version ‖ requestNonce)
```

### Padding

`padded = len_be32 ‖ innerJSON ‖ zero fill` to the next bucket. Buckets double from 256 B up to the request body limit. Both directions pad before sealing, so neither request nor response length leaks more than a bucket.

## API

Current `version` = `0x01`. A frame with an unknown version byte is `400`.

Distinct HTTP status codes exist only for pre-decryption failures and carry no application meaning: `400` malformed or unopenable, `413` oversize, `429` rate limited, `500` fault. No meaningful `409`/`404`/`401`.

### `GET /` — health check

Whether the server is up. HTTP status: 200 if OK, error otherwise. Carries no data.

### `POST /` — call

Binary frame — sealed envelope, parsed after GCM verification. HTTP status codes: always 200.

Every action is sealed under `envelopeKey`. There is no server-side device enrollment or sessions management.

Every outcome is a field inside the sealed response. Responses are padded to size buckets before sealing.

#### Action `sync`

Push writes, pull since `seq`

```
sync request   { "action": "sync", "since": seq,
                 "writes": [ { blindedId, v, writeId, deleted, payload } ] }

sync response  { "results": [ { blindedId, status, v, seq } ],
                 "changes": [ { blindedId, v, writeId, deleted, payload } ],
                 "nextSeq": seq, "more": bool }
```

`results` carries one entry per submitted write. **`v` and `seq` must be echoed** — without them the client cannot advance and every later write conflicts.

| `status`    | Description                                              |
| ----------- | -------------------------------------------------------- |
| `accepted`  | Stored. `v` and `seq` are the values now on the server   |
| `conflict`  | `v != storedV + 1`. `v` is the server's current version  |
| `too_large` | Payload over the configured note limit                   |
| `exhausted` | `v` is at `u32::MAX`; the note accepts no further writes |
| `quota`     | Storage limit reached                                    |

`more` is set when `changes` was truncated by the response size limit; the client pulls again from `nextSeq`.

#### Action `get_recovery_blob`

Read `contentKeyEncrypted`

```
get_recovery_blob request   { "action": "get_recovery_blob" }

get_recovery_blob response  { "blob": bytes, "v": u32 }
```

#### Action `put_recovery_blob`

Write `contentKeyEncrypted`

```
put_recovery_blob request   { "action": "put_recovery_blob", "v": u32, "blob": bytes }

put_recovery_blob response  { "status": "accepted" | "conflict" }
```

A `put` follows the same `v == storedV + 1` rule as notes. On `conflict` the client should report that the recovery phrase was rotated on another device.

## HKDF label registry

Every `info` label in the protocol, in one place. New labels must not collide; a changed derivation bumps its `/v`.

| Label                                          | Derives             | From                   |
| ---------------------------------------------- | ------------------- | ---------------------- |
| `native-note/envelope/v1`                      | `envelopeKey`       | API key                |
| `native-note/id-blind/v1`                      | `blindingKey`       | Content key            |
| `native-note/note/v1`                          | `noteKey` per write | Content key            |
| `native-note/localdb/v1`                       | `localDbKey`        | `argonOut ‖ machineId` |
| `native-note/machine-chain/v1/seed`            | chain seed          | `argonOut`             |
| `native-note/machine-chain/v1/<i>[/<attempt>]` | round scalar        | previous round         |
| `native-note/machine-chain/v1/out`             | `machineId`         | last round             |

### Limits

All configurable via [server config](../server/DESIGN.md#server-config).

| Limit                        | Default                      | Exceeded                       |
| ---------------------------- | ---------------------------- | ------------------------------ |
| Note payload                 | 1 MiB                        | `too_large` in the response    |
| Request body                 | 2 MiB                        | HTTP `413`                     |
| Requests per minute          | 60                           | HTTP `429`                     |
| Unopenable frames per minute | 10                           | HTTP `429`, per source address |
| Total stored bytes           | unset (available disk space) | `quota` in the response        |
