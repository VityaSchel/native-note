# Native Note Client Architecture

## Local DB

SQLCipher, WAL, `synchronous=FULL`. Foreign keys enforced with explicit `ON DELETE`.

Local durable save happens every ~300 ms debounce, no `v` bump

```sql
CREATE TABLE note (
    uuid      BLOB PRIMARY KEY NOT NULL,
    body      TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    deleted   INTEGER NOT NULL DEFAULT 0,
    dirty     INTEGER NOT NULL DEFAULT 0,
    v         INTEGER NOT NULL DEFAULT 0,
    seq       INTEGER
) STRICT;
CREATE VIRTUAL TABLE note_fts USING fts5(body, content=note);
CREATE TABLE meta (k TEXT PRIMARY KEY NOT NULL, v BLOB NOT NULL) STRICT;
```

Timestamps are epoch milliseconds, the same representation [note content](../docs/PROTOCOL.md#content) uses on the wire, so syncing needs no date conversion. Everything sits behind SQLCipher, so columns are plaintext to SQLite and FTS5 works. `dirty` marks pending pushes — the outbox is a flag, not a table. `meta` holds the Content key, API key, server URL, last pulled `seq`, and the recovery blob's pinned `v`, only when sync is configured.

### Local DB encryption

Unlocks the app. Only used for app database encryption, never leaves the device. Derived from the unlock password. Optionally bounded to the machine using secure hardware element. On some platforms optionally storable under current biometrics set for authentication.

```
argonOut   = Argon2id(password, localSalt, argonParams, 32)
machineId  = hardwareChain(argonOut, rounds)
localDbKey = HKDF-SHA256(argonOut ‖ machineId, salt: localSalt, info: "native-note/localdb/v1", 32)
```

`localDbKey` is passed as a **raw key** (`PRAGMA key = "x'<64 hex>'"`), not a passphrase.

#### `hardwareChain`

`rounds` sequential operations on the device's secure hardware, each feeding the next:

```
x = HKDF-SHA256(argonOut, info: "native-note/machine-chain/v1/seed", 32)
for (i in 0 ..< rounds) {
    x = hardwareOp(x, i)
}
machineId = HKDF-SHA256(x, info: "native-note/machine-chain/v1/out", 32)
```

`hardwareOp` is platform-specific and must satisfy three properties:

1. **Only this physical device can compute it.** The hardware key is non-extractable, so a disk image cannot reproduce `machineId` at any password length.
2. **It never prompts.** Biometric or presence gating would break the password-only path.
3. **It succeeds for every input.** A wrong password must yield a different chain, not a failure. Any construction where the hardware rejects a wrong password early hands the attacker a cheap oracle and collapses the cost per guess from `rounds` operations to one.

Operations serialize through one chip, so the cost per guess is fixed regardless of how much hardware an attacker brings. This is binding plus an unparallelizable floor, not a lockout — there is no attempt counter.

Platforms without secure hardware omit `machineId` and warn in UI; Argon2id alone carries those users.

#### Unlock parameters

`localSalt`, `argonParams` and `rounds` are needed *before* the database can be opened, so they cannot live inside it. They are stored in the app's private data directory as plaintext, alongside the encrypted database. Each platform documents the exact path and format in its own architecture file.

Tampering is fail-closed, not a weakening: altering any of them changes `localDbKey`, so the database simply refuses to open. Lowering `argonParams` or `rounds` cannot make an attacker's guessing cheaper, because the values that produced the key are the ones that must be reproduced.

`rounds` and `argonParams` are calibrated at setup: Argon2id to ~1.0 s with floor `m=256 MiB, t=3, p=4`, the chain to ~1.0 s. Calibrating `rounds` is safe in a way software calibration is not: an attacker must use this device's chip, so the measured cost is their cost.

#### Changing the password

`localDbKey` changes with the password, so the database is rekeyed: write the new unlock parameters to a **new** file keeping the old, `PRAGMA rekey`, verify a fresh open with the new key, only then delete the old file. Startup tries the new file and falls back to the old, so a crash at any point leaves the database openable.

#### Unlocking with biometrics

Optional, off by default. When enabled, `localDbKey` is stored in the platform's key store linked to the current biometric enrollment, so the OS invalidates it if the enrolled set changes.

The unlock screen always offers the password form. When biometric unlock is enabled it also offers a biometric button beside it:

- Prompt dismissed, cancelled or failed to authenticate — silently return to the unlock screen. The user can press the button again or type the password.
- Read or decryption fails — show an error, then return to the same unlock screen.

## Recovery flow

Only applicable for when server and e2ee sync are configured. [Recovery key](../docs/PROTOCOL.md#recovery-key) is used to decrypt server-stored [Content key](../docs/PROTOCOL.md#content-key) blob. Recovery key only restores Content key, so on its own it's not enough to configure a new device for sync.

Three forms of recovery credential:

- QR code carrying the pairing credential as raw bytes, in QR byte mode
- Saved file carrying the same 64 bytes verbatim
- 24 words mnemonic, BIP39 encoding, English wordlist, with the API key presented separately as hex. The checksum is only reliable for a UI check, a real check is GCM verification.

QR code and saved file carry the pairing credential. No `v` field, checksum is closed by GCM verification.

```
apiKey(32) ‖ recoveryKey(32)
```

Mnemonic carries the Recovery key alone:

```
256-bit entropy + 8-bit checksum = 264 bits ÷ 11 bits/word = 24 words
```

Server URL is not encoded in either.

**Setup:**
1. Fetch `contentKeyEncrypted` from the server and pull `v` from its metadata, if it exists
2. Generate the Recovery key using cryptographically secure pseudo random number generator
3. Offer any of three forms for recovery credential to be saved
   For QR codes: generate and display QR code; do not block screenshots or screen capture
   For saved file: write file directly to the location user chooses via native filesystem dialog
   For mnemonic: display three columns of words, selectable/copyable as text and the API key as hex; require three random words to be filled back in to prove they were actually securely stored
4. Encrypt Content key with Recovery key and append `v = storedV + 1`
5. Upload the blob and expect the server to confirm `v` wasn't overwritten during this flow
6. Enable sync

**Restore:**
1. Offer three ways to input recovery credential:
   For QR codes: native in-app camera scan, or choosing an image from the gallery or filesystem. Read the raw bytes, never a decoded string.
   For saved file: native filesystem dialog.
   For mnemonic: 24 word inputs with paste-across, wordlist autofill, and immediate checksum validation; API key entered as hex on the same screen.
   Every path also asks for the server URL, which is not part of the credential.
2. Authenticate with the API key and fetch `contentKeyEncrypted` from the server URL
3. Decrypt Content key with Recovery key
4. Start pulling all notes from `seq = 0` into memory, implement reasonable fail gate on Content key validity
5. Mandate setting a new [local DB password](#local-db-encryption) for app unlock

## Pull verification

On every pull a client must check the server's response against its own state.

- Every note held locally must still be present. A note that vanishes without a valid tombstone means withholding or tampering.
- No note may move backwards in `v`.
- Each decrypted `uuid` must re-derive the `blindedId` it arrived under.
- Every tombstone must decrypt. One that does not was forged by someone holding the API key.

## Conflicts

Conflicts surface during sync: the incoming version is in memory, and ours is already on disk. No third copy is created.

- **Keep mine** — discard the in-memory server version and re-push ours at `serverV + 1`.
- **Keep theirs** — write the in-memory server version over our row on disk.

The prompt never blocks the sync queue; other notes keep syncing. Retries use exponential backoff with jitter so two devices cannot livelock re-pushing at `v + 1` against each other.

## Exports

```
salt        = 128-bit random
argonParams = m_be32 ‖ t_be32 ‖ p_be32
exportKey   = Argon2id(passphrase, salt, argonParams, 32)
header      = "NNEXPORT1" ‖ argonParams ‖ salt
file        = header ‖ nonce ‖ ciphertext ‖ tag
              # AES-256-GCM(exportKey, zipBytes, aad: header)
```

The parameters travel in the header because the recipient has only the passphrase.
