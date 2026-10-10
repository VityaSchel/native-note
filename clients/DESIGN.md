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

Timestamps are epoch milliseconds, the same representation [note content](../docs/PROTOCOL.md#content) uses on the wire, so syncing needs no date conversion. Everything sits behind SQLCipher, so columns are plaintext to SQLite and FTS5 works. `dirty` marks pending pushes — the outbox is a flag, not a table. `seq` stays `NULL`, since a change carries no `seq`. Search matches whole words, and the last word as a prefix once it has two characters; results show as one list ranked by relevance. A search survives lock and reruns on unlock. `meta` holds the Content key, API key, server URL, last pulled `seq`, and the recovery blob's pinned `v`, only when sync is configured.

### Local DB encryption

Unlocks the app. Only used for app database encryption, never leaves the device. Derived from the unlock password. Optionally bounded to the machine using secure hardware element. On some platforms optionally storable under current biometrics set for authentication.

```
localSalt  = 128-bit random
argonOut   = Argon2id(password, localSalt, argonParams, 32)
machineId  = hardwareBinding()
localDbKey = HKDF-SHA256(argonOut ‖ machineId, salt: localSalt, info: "native-note/localdb/v1", 32)
```

Argon2id is version `0x13` with no secret or associated data, and `m` is in KiB. A password or passphrase enters it as UTF-8 bytes, unnormalized.

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

Only applicable when a sync server is configured. The recovery credential is the [Recovery key](../docs/PROTOCOL.md#recovery-key)'s 24 words; the API key and the server URL are not part of it. The word checksum is only a UI check; the real check is GCM verification.

Every recovery-blob `put` follows the [pin rule](../docs/PROTOCOL.md#recovery-key), and one whose response is lost is sent again unchanged. When a `put` conflicts and the blob it then gets [does not open](../docs/PROTOCOL.md#actions-get-and-put) under the Recovery key still in memory, setup routes to restore and rotation reports that another device rotated.

**Setup:**
1. Take the server URL and the API key as hex, and `get` the blob. A server that already holds one routes to restore before any words are shown.
2. Generate the Content key and the Recovery key with a CSPRNG.
3. Show the 24 words, selectable and copyable as text, and require three random words to be filled back in.
4. `put` the Content key encrypted under the Recovery key and, once that `put` has landed, store the Content key, API key, URL and pin in `meta`, and enable sync.

**Rotation:** shows new words the same way as setup, then `put`s the Content key under the new Recovery key. After it reports that another device rotated, rotation asks for the current words; once the fetched blob opens under them and holds this library's Content key, the pin takes its `v` and rotation can run again.

**Restore and add-device** are a join: restore runs it after setting up a library with a new [local DB password](#local-db-encryption), add-device from an unlocked library. A library that already holds a Content key refuses a join.
1. Take the 24 words, with paste-across, wordlist autofill and immediate checksum validation, the API key as hex, and the server URL. A lost API key is read from the server's [`api-key` file](../server/DESIGN.md#server-storage).
2. `get` the blob and open it with the Recovery key; nothing is stored unless it opens.
3. Store the Content key, API key, URL and the `get`'s `v` as the pin in `meta`.
4. Sync as usual from `seq = 0`. The library's existing notes are dirty, so they push.

## Pull verification

Each pulled change, tombstones included, must pass three checks:

- It decrypts and its content decodes.
- Its decrypted `uuid` re-derives the `blindedId` it arrived under.
- Its `v` is not below the local `v`. Equal is allowed, since a device's own write comes back, and is not applied.

A change that fails a check is reported and not applied, so a local note is removed only by a pulled tombstone that passes all three. A pulled `v` below the local `v`, a push `conflict` carrying a `v` below it, a `put` `conflict` below the pin, or a `nextSeq` below the client's `since`, means the server is behind the client: the client reports it and does not retry in a loop. A response whose `nextSeq` is below `since` is not applied at all, and `since` stays.

## Conflicts

Sync first flushes each note's pending save. A pulled change whose `v` is above the local `v`, for a note with unpushed edits, saves the unpushed text as a new note, with a new UUID, the unpushed `createdAt` and `updatedAt`, and dirty at `v = 0`, and applies the pulled version, in one transaction; when the bodies match, no copy is made. A dirty local tombstone yields to a pulled edit, and a pulled tombstone over unpushed edits keeps the text as the copy. The open editor follows the copy. A dirty note at `v = u32::MAX`, which [no write can follow](../docs/PROTOCOL.md#notes), takes the same copy path without a pull: the copy takes the unpushed text, and the original keeps it locally and is marked clean; a dirty tombstone there is marked clean without a push.

A pulled change carrying the `writeId` of our own unacknowledged write is that write already stored, after a lost response: it counts as `accepted`, not a conflict. An `accepted` write sets the note's `v` and clears `dirty` only if the note was not saved after the write was sealed; otherwise the note stays dirty and pushes at the new `v + 1`. Unacknowledged `writeId`s live in memory, each until a pull resolves it; after a relaunch, a lost response takes the copy path, where matching bodies make no copy.

A conflicted push stays dirty until its pull arrives. A failed sync retries at the next scheduled sync. A note whose payload would exceed the [note limit](../docs/PROTOCOL.md#limits) stays dirty and unpushed, and is reported.

## Exports

An export is the zip below, or, with a passphrase, this file:

```
salt        = 128-bit random
argonParams = m_be32 ‖ t_be32 ‖ p_be32
exportKey   = Argon2id(passphrase, salt, argonParams, 32)
header      = "NNEXPORT1" ‖ argonParams ‖ salt
file        = header ‖ nonce ‖ ciphertext ‖ tag
              # AES-256-GCM(exportKey, zipBytes, aad: header)
```

The parameters travel in the header because the recipient has only the passphrase.

Exports use the Argon2id floor, so any device can open them. Before hashing, a reader refuses `m` above 2 GiB or below `8p`, `t` outside 1–10 and `p` outside 1–16.

The zip holds one markdown file per live note, named from its title as one path component that ends in `.md`, holds no control character, `/` or `\`, takes at most 255 bytes, and is unique ignoring case and Unicode normalization. Entries are stored (method 0) under UTF-8 names with general-purpose flag bit 11 and no other flag, each local header matching its central record, and no extra field, comment or zip64 record; version, time and attribute fields are free. Export refuses a library of more than 65,534 live notes or a file over 512 MiB.

Each file is UTF-8: front matter with LF line endings, then the body byte for byte, CR included:

```
---
id: 0b8f1d2e-3a4b-4c5d-8e9f-001122334455
created: 2026-08-08T10:00:00.000Z
updated: 2026-08-08T10:05:00.000Z
v: 3
---
body
```

The fields come in this order and spelling only: `id` lowercase and hyphenated; `created` and `updated` as ISO 8601 in UTC with milliseconds on the proleptic Gregorian calendar, where year `0000` is 1 BC, and, for a year outside 0000–9999, a sign and the year zero-padded to six digits; `v` as a `u32` in decimal.

Import reads only this format, one import at a time, and refuses files over 512 MiB unread. A file that starts with `NNEXPORT1` opens with its passphrase; any other is read as the zip. Import finds entries through the central directory, which ends where the end record starts, and ignores bytes no entry covers before it. It checks every CRC-32, reads no meaning from names or times, and ignores versions, attributes, comments and extra fields of any kind, zip64's included. It refuses the whole archive over a method other than 0, a flag other than bit 11, an all-ones count, size or offset, a zip64 locator, a disk number other than 0, a local header whose flags, method, time, date, CRC-32, sizes or name differ from its central record, an entry whose two sizes differ, overlapping entries, a name that is not UTF-8 or has NUL, `\`, or an empty, `.` or `..` path component, a file in any other spelling or not UTF-8, or a repeated `id`. It adds notes whose `id` the library does not hold, dirty at `v = 0`, and skips every `id` it holds, live or deleted.
