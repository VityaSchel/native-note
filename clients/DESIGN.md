# Native Note Client Architecture

## Local DB

SQLCipher in WAL mode with `synchronous=FULL`, `fullfsync` and `checkpoint_fullfsync`; on macOS `synchronous=FULL` alone does not survive power loss. A database whose `user_version` is newer than the app is refused. `PRAGMA foreign_keys = ON` from v1, so every later relation declares its `ON DELETE`.

- A note saves at most ~300 ms after its first unsaved edit, and at once on leaving the note, lock, the app resigning active, sleep and quit.
- A new note is marked for sync only at its first edit. A New Note left empty is discarded: removed if no server has seen it, tombstoned otherwise.
- A local save never bumps `v` and never writes to a tombstone. Undo Delete restores the text as a new note with the deleted one's timestamps, until the library locks.
- A failed save retries with the latest text, across lock and unlock, and is reported once until no save fails. Lock does not wait for it and shows the failure on the lock screen.
- Quit with an unsaved edit asks first.

The library locks when the Mac sleeps, its screen locks or the user session switches away. Locking cancels a sync or Change Server check in flight and waits for it before closing the database; an unlock that finishes after one of these events locks again. Closing the window keeps the app running and the library unlocked.

Locking and quitting close the database, which checkpoints the WAL and deletes `-wal` and `-shm`: a locked library on disk is `notes.db`, indistinguishable from random, beside the public `app-lock.plist`. The sidecars, whose headers read as SQLite, exist while unlocked, while a lock keeps the database open to retry a failing save, and after a crash until the next lock.

```sql
CREATE TABLE note (
    uuid      BLOB PRIMARY KEY NOT NULL,
    body      TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    deleted   INTEGER NOT NULL DEFAULT 0,
    dirty     INTEGER NOT NULL DEFAULT 0,
    v         INTEGER NOT NULL DEFAULT 0,
    seq       INTEGER,
    pulled    INTEGER NOT NULL DEFAULT 0
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

Timestamps are epoch milliseconds, as in [note content](../docs/PROTOCOL.md#content), held as `Int64` and converted to `Date` only for display, so any pulled `i64` survives. Columns are plaintext inside SQLCipher, so FTS5 works. `dirty` is the outbox. `seq` stays `NULL`, since a change carries no `seq`. `meta` holds sync state: the Content key, API key, server URL, the last pulled `seq` with the blinded ID and `v` of the write there, and the recovery blob's pinned `v`.

Search matches whole words, and the last word as a prefix from two characters, ranked by relevance. A search survives lock and reruns on unlock.

### Local DB encryption

`localDbKey` encrypts the local database and never leaves the device. It derives from the unlock password, bound to the device's secure hardware where there is one.

```
localSalt  = 128-bit random
argonOut   = Argon2id(password, localSalt, argonParams, 32)
machineId  = hardwareBinding()
localDbKey = HKDF-SHA256(argonOut ‖ machineId, salt: localSalt, info: "native-note/localdb/v1", 32)
```

Argon2id is version `0x13` with no secret or associated data, `m` in KiB. A password or passphrase enters it as UTF-8 bytes, unnormalized.

`localDbKey` is a **raw key**, the literal `x'<64 hex>'` through `sqlite3_key_v2` and `sqlite3_rekey_v2`, never a passphrase; it opens libraries keyed with `PRAGMA key = "x'<64 hex>'"`.

The app keeps no copy of `localDbKey` while unlocked; SQLCipher holds it until the database closes. Derived keys stay in zeroizing key types, and scratch buffers holding key or password bytes are wiped after use. Strings are not wiped: the password, the API key's hex and the recovery words pass through them.

#### `hardwareBinding`

One operation on the device's secure hardware, independent of the password:

```
machineId = HKDF-SHA256(hardwareOp(), info: "native-note/machine-id/v1", 32)
```

`hardwareOp` is platform-specific and:

1. **Only this physical device can compute it.** The hardware key is non-extractable, so a disk image cannot reproduce `machineId`.
2. **It never prompts**, so the password alone unlocks.
3. **It is deterministic and takes no secret input.** Nothing derived from the password reaches the hardware: ECDH is symmetric, so `devicePriv·(sG)` equals `s·devicePub`, which an attacker computes from a guessed password's `s` and the public key in the stored key blob.

Without secure hardware, `machineId` is omitted, the UI warns, and Argon2id alone protects the library. A hardware key that cannot load, as on another device, is reported as notes bound to another device.

#### Unlock parameters

`localSalt` and `argonParams` are public and stored outside the database. `argonParams` is calibrated at setup and at every password change: from the floor `m=256 MiB, t=3, p=4`, only `m` rises, to the largest value whose in-process run takes at most 0.4 s, capped at 2 GiB; a password change never lowers it.

#### Changing the password

1. Confirm the current password with a fresh open
2. Write the new unlock parameters, with a fresh salt and recalibrated `argonParams`, to a pending file, keeping the current one
3. Rekey with `sqlite3_rekey_v2`
4. Verify a fresh open with the new key; on failure, reconnect with the old key, delete the pending file and keep the old password
5. Replace the current parameter file with the pending one

Unlock tries the pending file, then the current one, and keeps whichever opens the database, so a crash between steps leaves it openable. A parameter file is written to a temporary file, flushed with `F_FULLFSYNC`, renamed into place and its directory flushed, before the rekey it enables. An unreadable parameter file is an error, never a first run. Unlock never creates the database and treats an empty one as missing; setup sets aside, never deletes, a database left without parameter files, moving its sidecars first so an interrupted set-aside finishes on the next setup.

#### Forgotten password

The unlock screen offers to erase the library, behind a confirmation. Erasing deletes the biometric key, then the unlock parameters, then the database with its sidecars and set-aside copies, and returns to setup. A file that cannot be deleted is reported; once the parameters are gone, setup follows anyway.

#### Unlocking with biometrics

Optional, off by default. `localDbKey` is stored in the platform key store bound to the current biometric enrollment, which the OS invalidates when the enrolled set changes. The OS, not the app, decides a match.

The prompt is in the app's window, never a system alert. On macOS it is [`LAAuthenticationView`](https://developer.apple.com/documentation/localauthenticationembeddedui/laauthenticationview), created with a fresh `LAContext` per attempt and in the window before that context evaluates the key's access control. The key is read through the same context with interaction not allowed, then the context is invalidated, whatever the outcome. The view is never hidden, since the OS refuses a touch through a hidden view: it stays at full opacity behind the opaque password field.

The unlock screen listens whenever it is in front: at launch, on return to the app and after Lock. Listening pauses while another app is active, while a password is checked, and while the field shakes after a wrong password or a non-matching finger (a lockout does not shake). After a miss, a fresh attempt starts when the shake ends, so a resting wrong finger can use up the attempts until macOS locks Touch ID.

Touch ID stops on the unlock screen, with no retry click, after a lockout, an attempt the OS ends while the app is in front, or an attempt whose view left the window, until the next return to the app, and for a lockout until the OS has lifted it. A new unlock screen listens again unless biometrics are still locked out.

- Biometrics become unavailable: Touch ID drops until the next return to the app.
- The key fails to read, or no longer opens the database: show the error and forget the key. A key that cannot be forgotten stays, and Touch ID stops.
- The library fails to open after a touch for another reason: show the error, keep the key, and Touch ID stops.

Turning it on takes the password, checks the derived key opens the database, stores it, and is on only once a touch reads it back; waiting for the touch pauses while another app is active. A wrong password stores nothing; a wrong finger or an attempt the OS ends waits for a click to retry; anything else short of a matching touch deletes the key: cancel, a lockout, biometrics becoming unavailable, a failed read, a key that reads back differently, quit, lock, or a password change. Turning it off asks nothing.

Onboarding offers it after the password step, with the password just set, held only until that step ends. Changing the password, or setting up a new library in the same place, deletes the stored key; after a password change the same sheet offers to turn it on again.

## Recovery flow

Applies only with a sync server. The recovery credential is the [Recovery key](../docs/PROTOCOL.md#recovery-key)'s 24 words, without the API key or server URL. The word checksum is a typing check; GCM verification is the real one.

Every recovery-blob `put` follows the [pin rule](../docs/PROTOCOL.md#recovery-key):

- A `put` whose response is lost is sent again unchanged.
- A `put` whose answer never arrives intact, as when a proxy forwards it and then fails, is settled by a `get`: a blob that opens under the Recovery key still in memory means it landed. When that `get` fails, or a conflict's `get` fails, the outcome is unknown and the words stay in memory for a retry.
- A `put` counts as not sent only when every attempt failed to reach the server. A `put` given up on can still land later, since nothing in it expires.
- A conflict whose fetched blob [does not open](../docs/PROTOCOL.md#actions-get-and-put) under the Recovery key in memory routes setup to the join, and makes rotation report that another device rotated.

Cancel stops setup, join and Change Server while nothing is stored, and is off while a recovery-blob `put` is in flight.

**Setup** is the last onboarding step, so a new or wiped Mac starts from its synced notes, and stays in Settings for later. Locking or quitting during onboarding drops its remaining offers.

1. Take the server URL and the API key as hex, and `get` the blob. A server that already holds one routes to the join before any words are shown.
2. Generate the Content key and the Recovery key with a CSPRNG.
3. Show the 24 words hidden until revealed, every hidden word drawn as the same placeholder, then require three random words typed back. Copying puts the numbered list on this Mac's pasteboard only, marked concealed and transient, and clears it on cancel, lock or quit unless something else was copied over it.
4. `put` the Content key encrypted under the Recovery key and, once that `put` has landed, store the Content key, API key, URL and pin in `meta`, and enable sync.

**Turn Off Sync and Change Server:** Turn Off Sync forgets only the server address and API key; the Content key, the pin, the last pulled `seq` with its mark, and every note's version stay. Set Up Sync on such a library, or Change Server on a syncing one, checks the server: one that holds this library takes it back with no words; an empty one gets it under a new recovery phrase, with every note pushed as new and tombstones dropped, while the old server keeps its sealed copy; one that holds another library is refused, since two libraries cannot merge.

**A replaced API key:** Change Server with the same address takes the new key. The server holds this library when it answers under the new key with a recovery blob at or above the pin and, once this Mac has pulled, with the write its last pull ended on, by blinded ID at that `v` or later, whether or not it opens, so a write forged with a leaked key cannot block the change. A mistyped key, a server holding another library or one restored from an older backup leaves the old address, key and sync as they were; without the recovery phrase this is as close as the Mac can check.

**Rotation:** shows new words as setup does, then `put`s the Content key under the new Recovery key. After it reports that another device rotated, rotation asks for the current words; once the fetched blob opens under them and holds this library's Content key, the pin takes its `v` and rotation can run again.

**Restore and add-device** are a join: restore runs after setting up a library with a new [local DB password](#local-db-encryption), add-device from an unlocked library. A library that already holds a Content key refuses a join.

1. Take the server URL and the API key as setup does, then the 24 words, one per field. A paste splits at whitespace and commas, trims anything but letters from each word's ends, and fills the fields from the current one onward, or by number when every word follows its number, as in the copied list. Leaving a field lowercases an all-letter word and completes a prefix only one list word starts with. Words no list word starts with, and 24 list words that fail the checksum, are flagged. A lost API key is read from the server's [`api-key` file](../server/DESIGN.md#server-storage).
2. `get` the blob and open it with the Recovery key; nothing is stored unless it opens. A server that holds no blob routes back to setup.
3. Store the Content key, API key, URL and the `get`'s `v` as the pin in `meta`.
4. Sync from `seq = 0`. The library's existing notes are dirty, so they push.

## Sync

A sync runs 30 s after the last edit, when the app becomes or stops being active, after unlock, and on Sync Now, one at a time; requests made during a sync share the next one. It pushes every dirty note, as many per request as fit the [body limit](../docs/PROTOCOL.md#limits), and pulls until `more` is clear. Each response applies in one transaction with its `since`. Saves that fall due meanwhile wait, and an edit typed on a note a pull replaced moves to that note's copy.

A save carries the `v` its edit began at. `pulled` marks a row whose text a pull wrote; a save whose `v` no longer matches such a row lands as a new note, which the editor follows, so no save writes over pulled text.

The server URL may be plain `http`, since everything past the URL is sealed; the app allows arbitrary loads under App Transport Security. Requests carry only fixed headers, the same on every Mac, so nothing outside the envelope tells devices, builds or languages apart.

## Pull verification

Each pulled change, tombstones included, must pass three checks:

- It decrypts and its content decodes.
- Its decrypted `uuid` re-derives the `blindedId` it arrived under.
- Its `v` is not below the local `v`. Equal passes, since a device's own write comes back, and is not applied.

A change that fails a check is reported and not applied, so only a pulled tombstone that passes all three removes a local note. A pulled `v` below the local `v`, a push `conflict` carrying a `v` below it, a `put` `conflict` below the pin, or a `nextSeq` below the client's `since` means the server is behind the client: the client reports it and does not retry in a loop. A response whose `nextSeq` is below `since` is not applied at all, and `since` stays.

## Conflicts

Sync first flushes each note's pending save. A pulled change whose `v` is above the local `v`, for a note with unpushed edits, saves the unpushed text as a new note, with a new UUID, the unpushed `createdAt` and `updatedAt`, and dirty at `v = 0`, and applies the pulled version, in one transaction; when the bodies match, no copy is made. A dirty local tombstone yields to a pulled edit, and a pulled tombstone over unpushed edits keeps the text as the copy. The open editor follows the copy. A dirty note at `v = u32::MAX`, which [no write can follow](../docs/PROTOCOL.md#notes), takes the same copy path without a pull: the copy takes the unpushed text, and the original keeps it locally and is marked clean; a dirty tombstone there is marked clean without a push.

A pulled change carrying the `writeId` of our own unacknowledged write is that write already stored after a lost response: it counts as `accepted`, not a conflict. An `accepted` write sets the note's `v` and clears `dirty` only if the note was not saved after the write was sealed; otherwise the note stays dirty and pushes at the new `v + 1`. Unacknowledged `writeId`s live in memory until a pull resolves each; after a relaunch, a lost response takes the copy path, where matching bodies make no copy.

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
