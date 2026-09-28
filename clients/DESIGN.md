# Native Note Client Architecture

## Local DB

SQLCipher, WAL, `synchronous=FULL` with `fullfsync` and `checkpoint_fullfsync` on; on macOS `synchronous=FULL` alone does not survive power loss. A database whose `user_version` is newer than the app is refused, not opened. `PRAGMA foreign_keys = ON` from v1, so every relation added later carries an explicit `ON DELETE`.

A note saves locally at most ~300 ms after its first unsaved edit, so continuous typing still saves. Leaving the note, locking, and the app resigning active, sleeping, or quitting save at once. A local save never bumps `v` and never writes to a tombstone. A failed save keeps retrying with the latest text, including across lock and unlock, and is reported once until no save is failing. Lock does not wait for a failing save and shows its failure on the lock screen. Quit with an unsaved edit asks first, and only Quit Anyway quits.

Locking and quitting close the database, which checkpoints the WAL and deletes `-wal` and `-shm`, so once locked the database on disk is `notes.db` alone, indistinguishable from random, beside the public unlock parameters in `app-lock.plist`. The sidecars exist while unlocked, while a lock keeps the database open to retry a failing save, and after a crash until the next lock; their headers read as SQLite.

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
CREATE INDEX note_updatedAt ON note (updatedAt DESC);
CREATE INDEX note_dirty ON note (dirty) WHERE dirty = 1;

CREATE VIRTUAL TABLE note_fts USING fts5(body, content=note);

CREATE TRIGGER note_fts_insert AFTER INSERT ON note BEGIN
    INSERT INTO note_fts (rowid, body) VALUES (new.rowid, new.body);
END;
CREATE TRIGGER note_fts_delete AFTER DELETE ON note BEGIN
    INSERT INTO note_fts (note_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
END;
CREATE TRIGGER note_fts_update AFTER UPDATE ON note BEGIN
    INSERT INTO note_fts (note_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
    INSERT INTO note_fts (rowid, body) VALUES (new.rowid, new.body);
END;

CREATE TABLE meta (k TEXT PRIMARY KEY NOT NULL, v BLOB NOT NULL) STRICT;
```

`content=note` is an external-content index: without the three triggers it is populated once and never updated again.

Timestamps are epoch milliseconds, the same representation [note content](../docs/PROTOCOL.md#content) uses on the wire, so syncing needs no date conversion. Everything sits behind SQLCipher, so columns are plaintext to SQLite and FTS5 works. `dirty` marks pending pushes — the outbox is a flag, not a table. Search matches whole words, and the last word as a prefix once it has two characters; results show as one list ranked by relevance. A search survives lock and reruns on unlock. `meta` holds the Content key, API key, server URL, last pulled `seq`, and the recovery blob's pinned `v`, only when sync is configured.

### Local DB encryption

Unlocks the app. Only used for app database encryption, never leaves the device. Derived from the unlock password. Optionally bounded to the machine using secure hardware element. On some platforms optionally storable under current biometrics set for authentication.

```
argonOut   = Argon2id(password, localSalt, argonParams, 32)
machineId  = hardwareBinding()
localDbKey = HKDF-SHA256(argonOut ‖ machineId, salt: localSalt, info: "native-note/localdb/v1", 32)
```

`localDbKey` is passed as a **raw key**, the literal `x'<64 hex>'` through `sqlite3_key_v2` and `sqlite3_rekey_v2`, not a passphrase. It opens libraries keyed with `PRAGMA key = "x'<64 hex>'"`.

The app keeps no copy of `localDbKey` while unlocked; SQLCipher holds it until the database closes. Derived keys stay in zeroizing key types, and the scratch buffers the app fills with key or password bytes are wiped after use. The password string is not wiped.

#### `hardwareBinding`


Hardware binding adds protection against a stolen disk image, but unlike Argon2id does not add per-guess cost. One operation on the device's secure hardware, independent of the password.

```
machineId = HKDF-SHA256(hardwareOp(), info: "native-note/machine-id/v1", 32)
```

`hardwareOp` is platform-specific and must satisfy three properties:

1. **Only this physical device can compute it.** The hardware key is non-extractable, so a disk image cannot reproduce `machineId` at any password length.
2. **It never prompts.** Biometric or presence gating would break the password-only path.
3. **It is deterministic and takes no secret input.** Anything derived from the password must not reach the hardware: ECDH is symmetric, so `devicePriv·(sG)` equals `s·devicePub`, the attacker derives `s` from their own password guess, and the device public key is recoverable from the stored key blob.

Platforms without secure hardware omit `machineId` and warn in UI; Argon2id alone carries those users. A hardware key that cannot load, as on another device, is reported as notes bound to another device.

#### Unlock parameters

`localSalt` and `argonParams` are public key parameters, so they're stored outside of the database. They must exactly match the values that produced the key. `argonParams` is calibrated at setup and at every password change: from the floor `m=256 MiB, t=3, p=4`, only `m` rises, to the largest value whose measured in-process run takes at most 0.4 s, capped at 2 GiB, and a password change never lowers it. A cold unlock in a freshly launched app costs more than an in-process run, so 0.4 s lands a cold unlock around 0.4–1 s.

#### Changing the password

`localDbKey` changes with the password, so the database is rekeyed:

1. Confirm the current password with a fresh open
2. Write the new unlock parameters, with a fresh salt and recalibrated `argonParams`, to a pending file, keeping the current one
3. Rekey with `sqlite3_rekey_v2`
4. Verify a fresh open with the new key; if it fails, reconnect the store with the old key, delete the pending file and keep the old password
5. Replace the current key file with the pending one

Unlock tries the pending file, then the current one, and keeps whichever opens the database as the only file, so a crash between any steps leaves it openable. An unreadable parameter file is an error, never a first run. Unlock never creates the database and treats an empty one as missing; setup sets aside a database left without parameter files rather than deleting it, moving its sidecars first so an interrupted set-aside finishes on the next setup.

#### Forgotten password

The unlock screen offers to erase the library and start over, behind a confirmation. Erasing deletes the biometric key, then the unlock parameters, which leaves the notes unrecoverable, then the database with its sidecars and any set-aside copies, and returns to setup. A file that cannot be deleted is reported; once the parameters are gone the app returns to setup anyway.

#### Unlocking with biometrics

Optional, off by default. When enabled, `localDbKey` is stored in the platform's key store linked to the current biometric enrollment, so the OS invalidates it if the enrolled set changes. The OS does the fingerprint check against the key's access control; the app never decides a match itself.

The biometric prompt lives inside the app's window, never in a system alert. On macOS it is [`LAAuthenticationView`](https://developer.apple.com/documentation/localauthenticationembeddedui/laauthenticationview), and pairing comes before evaluation: the view is created with its `LAContext` and is in the window before that context evaluates the key's access control. The key is then read through the same context with interaction not allowed, and the context is invalidated after the read, whatever the outcome. Each attempt gets a fresh context.

When biometric unlock is enabled, the screen listens for a touch whenever it is in front: at launch, on returning to the app, and right after the user locks. A touch with an enrolled finger unlocks without a click. While listening, the paired view stays in the window at full opacity, behind the password field and covered by the field's opaque background; it is never hidden, because the OS refuses a touch through a hidden view. It is not an accessibility element. The screen says whether Touch ID can be used:

- Usable: listening, in the background, while a password is checked, while the field shakes, and while the library opens after a touch. A finger that does not match keeps it usable.
- Stopped on this screen: a lockout (macOS locks Touch ID Mac-wide after five misses in a row), an attempt the OS ends while the app is in front, or a library that fails to open after a touch.

Listening continues while the user types. It stops while another app is active, so that app's biometric prompts keep working, while a password is checked, and while the field shakes. VoiceOver announces a wrong password and a stop of Touch ID. While the library opens after a touch, the field is disabled.

A wrong password and a finger that does not match shake the field. A shake asked for while one runs is ignored.

LocalAuthentication reports a finger that does not match only when an attempt ends with failed authentication, and that is the only trigger for its shake; a lockout does not shake. Nothing listens while the field shakes: after a wrong password listening resumes when the shake ends, not when the check ends, and after a miss a fresh attempt listens when the shake ends, without a click. A resting wrong finger can therefore use up the attempts until macOS locks Touch ID.

The lock screen offers no retry click. Three stops end on the next return to the app: a lockout the OS has lifted, an attempt the OS ended, and an attempt whose view left the window.

Other outcomes:

- Biometrics become unavailable: the screen drops Touch ID until the next return to the app.
- Reading the key fails: show an error and forget the stored key.
- The stored key no longer opens the database: the same.
- A stored key that cannot be forgotten stays, and Touch ID stops on this screen.
- The library fails to load for another reason: show the error, keep the key and stop Touch ID on this screen.

A new unlock screen listens again unless the OS still has biometrics locked out or another app is in front.

Turning it on asks for the password, derives the key and confirms it opens the database, stores it, then listens in the same sheet for a touch that reads it back. Listening in the sheet also stops while another app is active. In the sheet, a wrong finger or an attempt the OS ends waits for a click to try again. A wrong password stores nothing. Anything else short of a matching touch deletes the key and leaves the option off: cancelling, a lockout, biometrics becoming unavailable, a failed read, a key that reads back differently, quitting, or a lock or password change before the touch. The option shows on only once the touch confirms it. Turning it off asks nothing.

Changing the password deletes the stored key, and so does setting up a new library in the same place.

The Settings window, where Touch ID unlock is turned on and off, offers its settings only while the library is unlocked.

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

Exports use the Argon2id floor, so any device can open them. A reader refuses more than 2 GiB, 10 passes or 16 lanes before hashing.

The zip holds one uncompressed markdown file per live note, named from its title. Each file starts with front matter `id`, `created`, `updated` (ISO 8601 UTC with milliseconds) and `v`, then the body byte for byte.

Import reads only this format, one import at a time, and waits until earlier conflicts are resolved. It refuses files over 512 MiB unread. A note already in the library is skipped when identical and otherwise raises the [conflict](#conflicts) choice; keep theirs saves the export's text as a new edit. A note deleted here stays deleted.
