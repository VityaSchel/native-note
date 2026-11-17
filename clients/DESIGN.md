# Native Note Client Architecture

## Local DB

SQLCipher in WAL mode with `synchronous=FULL`, `fullfsync` and `checkpoint_fullfsync`; on macOS `synchronous=FULL` alone does not survive power loss. Every connection sets a 5 s busy timeout. A database whose `user_version` is newer than the app is refused. `PRAGMA foreign_keys = ON` from v1, so every later relation declares its `ON DELETE`.

- A note saves at most ~300 ms after its first unsaved edit, and at once on leaving the note, lock, the app resigning active, sleep and quit.
- Budgets: a force-quit loses at most the last 400 ms of typing; a keystroke on 1,000 notes costs at most 20 times one in a plain text view and 3 times one on 10 notes; a save takes at most 100 ms at the 95th percentile.
- A new note is marked for sync only at its first edit. A new note left empty, or holding only whitespace, is discarded, on lock and quit too: removed if no server has seen it, kept if a pull has written it since the list last showed it, tombstoned otherwise; one discarded during its first push is tombstoned [when that push lands](#conflicts).
- A local save never bumps `v` and never writes to a tombstone. Undoing a delete restores the text as a new note with the deleted one's timestamps and `ext`, until the library locks.
- A failed save retries with the latest text, across lock and unlock, and is reported once until no save fails. Lock does not wait for it and shows the failure on the lock screen.
- Quit with an unsaved edit asks first.

The library locks when the device sleeps, its screen locks or the user session switches away. Locking cancels a sync or Change Server check in flight and waits for it before closing the database; an unlock that finishes after one of these events locks again. Locking ends an open export or import panel and forgets an import waiting for its passphrase, and a locked library refuses an export. Closing the window keeps the app running and the library unlocked.

Locking and quitting close the database, which checkpoints the WAL and deletes `-wal` and `-shm`: a locked library on disk is `notes.db`, indistinguishable from random, with its [unlock record](#unlock-record) in the key store or, in a build that cannot reach it, the `app-lock.plist` beside it. The sidecars, whose headers read as SQLite, exist while unlocked, while a lock keeps the database open to retry a failing save, and after a crash until the next lock.

```sql
CREATE TABLE note (
    uuid      BLOB PRIMARY KEY NOT NULL,
    body      TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    deleted   INTEGER NOT NULL DEFAULT 0,
    dirty     INTEGER NOT NULL DEFAULT 0,
    v         INTEGER NOT NULL DEFAULT 0,
    pulled    INTEGER NOT NULL DEFAULT 0,
    ext       BLOB NOT NULL DEFAULT x''
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

Timestamps are epoch milliseconds, as in [note content](../docs/PROTOCOL.md#content), held as `Int64` and converted to `Date` only for display, so any pulled `i64` survives. Columns are plaintext inside SQLCipher, so FTS5 works. `dirty` is the outbox. `ext` holds the note's [`ext`](../docs/PROTOCOL.md#content) byte for byte: a pull writes it, a push sends it, a local edit never changes it, a new or imported note holds it empty, deleting a note empties it, and a conflict copy or a restored note keeps its source's. `meta` holds sync state: the Content key, API key, server URL, the last pulled `seq` with the blinded ID and `v` of the write there, the recovery blob's pinned `v`, and the IDs of notes first pushed since the last pull that left `more` clear.

Search matches whole words, and the last word as a prefix from two characters, ranked by relevance. A search survives lock and reruns on unlock.

### Local DB encryption

`localDbKey` encrypts the local database and never leaves the device. It is 256 random bits drawn at setup and stored only wrapped by `unlockKey`, which derives from the unlock password, bound to the device's secure hardware where there is one.

```
localSalt  = 128-bit random
argonOut   = Argon2id(password, localSalt, argonParams, 32)
machineId  = hardwareBinding()
unlockKey  = HKDF-SHA256(argonOut ‖ machineId, salt: localSalt, info: "native-note/unlock/v1", 32)
wrappedKey = AES-256-GCM(unlockKey, nonce: 96-bit random, aad: "native-note/localdb-key/v1", localDbKey)   # nonce ‖ ciphertext ‖ tag, 60 bytes
```

Argon2id is version `0x13` with no secret or associated data, `m` in KiB. A password or passphrase enters it as UTF-8 bytes, unnormalized.

`localDbKey` is a **raw key**, the literal `x'<64 hex>'` through `sqlite3_key_v2`, never a passphrase; it opens libraries keyed with `PRAGMA key = "x'<64 hex>'"`. A `wrappedKey` whose tag fails reads as a wrong password; one that unwraps to a key the database refuses is reported as a database its record does not open.

The app keeps no copy of `localDbKey` while unlocked, except while turning on biometrics waits for the touch that reads it back and while a password change wraps it again; SQLCipher holds it until the database closes. Derived keys stay in zeroizing key types, and scratch buffers holding key or password bytes are wiped after use. Strings are not wiped: the password, the API key's hex and the recovery words pass through them.

#### `hardwareBinding`

One operation on the device's secure hardware, independent of the password:

```
machineId = HKDF-SHA256(hardwareOp(), info: "native-note/machine-id/v1", 32)
```

`hardwareOp` is platform-specific and:

1. **Only this physical device can compute it.** The hardware key is non-extractable, so a disk image cannot reproduce `machineId`.
2. **It never prompts**, so the password alone unlocks.
3. **It is deterministic and takes no secret input.** No password-derived input: ECDH is symmetric, so a guesser could compute the result from each guess and the public key in the stored key blob.

Without secure hardware, `machineId` is omitted, the UI warns, and Argon2id alone protects the library. A hardware key that cannot load, as on another device, is reported as notes bound to another device.

#### Unlock record

The unlock record holds `localSalt`, `argonParams`, the hardware key blob and `wrappedKey`, outside the database: in the platform key store, readable only by the app and never backed up or synced, or, in a build that cannot reach the key store, in a file beside the database. `argonParams` is calibrated at setup and at every password change: from the floor `m=256 MiB, t=3, p=4`, only `m` rises, in multiples of `8p` KiB, to the largest of up to four timed in-process runs that takes at most 0.4 s, capped at 2 GiB; a password change never lowers it.

#### Changing the password

1. Confirm the current password: unwrap `localDbKey` and open the database with it
2. Wrap `localDbKey` under the new `unlockKey`, with a fresh salt and recalibrated `argonParams`, and check the new record unwraps
3. Replace the unlock record in one atomic write

The database and the key saved for biometrics stay as they are. One change runs at a time. Lock and quit cancel a running change only before step 3 and wait for it either way; unlock and erase wait for it too. A record file is written to a temporary file, flushed with `F_FULLFSYNC`, renamed into place and its directory flushed; a key store item is updated in place. An unreadable record is an error, never a first run. Unlock never creates the database and treats an empty one as missing; setup sets aside, never deletes, a database left without an unlock record, moving its sidecars first so an interrupted set-aside finishes on the next setup.

#### Forgotten password

The unlock screen offers to erase the library, behind a confirmation. Erasing deletes the biometric key, then the unlock record, then the database with its sidecars and set-aside copies, and returns to setup. Without its record the database cannot be opened. A file that cannot be deleted is reported; once the record is gone, setup follows anyway.

#### Unlocking with biometrics

Optional, off by default. `localDbKey` is stored in the platform key store bound to the current biometric enrollment, which the OS invalidates when the enrolled set changes. The OS, not the app, decides a match.

The prompt is in the app's window, never a system alert.

The unlock screen listens whenever it is in front: at launch, on return to the app and after locking. Listening pauses while another app is active, while a password is checked, and while a wrong password or a non-matching finger is reported; a lockout is not reported this way. After a miss, a fresh attempt starts once it has been reported, so a resting wrong finger can use up the attempts until the OS locks biometrics.

Biometric unlock stops on the unlock screen, with no retry click, after a lockout, an attempt the OS ends while the app is in front, or an attempt whose view left the window, until the next return to the app, and for a lockout until the OS has lifted it. A new unlock screen listens again unless biometrics are still locked out.

- Biometrics become unavailable: biometric unlock drops until the next return to the app.
- The key fails to read, or no longer opens the database: show the error and forget the key. A key that cannot be forgotten stays, and biometric unlock stops.
- The library fails to open after a touch for another reason: show the error, keep the key, and biometric unlock stops.

Turning it on takes the password, checks the derived key opens the database, stores it, and is on only once a touch reads it back; waiting for the touch pauses while another app is active. A wrong password stores nothing; a wrong finger waits for a click to retry, and an attempt the OS ends waits for a click or the next return to the app; anything else short of a matching touch deletes the key: cancel, a lockout, biometrics becoming unavailable, a failed read, a key that reads back differently, quit, lock, or a password change. Turning it off asks nothing.

Onboarding offers it after the password step, with the password just set, held only until that step ends. A password change keeps the stored key; setting up a new library in the same place deletes it.

## Recovery flow

Applies only with a sync server. The recovery credential is the [Recovery key](../docs/PROTOCOL.md#recovery-key)'s 24 words, without the API key or server URL. The word checksum is a typing check; GCM verification is the real one.

Every recovery-blob `put` follows the [pin rule](../docs/PROTOCOL.md#recovery-key):

- A `get` or `put` whose response is lost is sent again unchanged, up to three attempts in all.
- A `put` whose answer never arrives intact, as when a proxy forwards it and then fails, or arrives as a `fault`, is settled by a `get`: a blob that opens under the Recovery key still in memory means it landed. When that `get` fails, or a conflict's `get` fails, the outcome is unknown and the words stay in memory for a retry.
- A `put` counts as not sent only when every attempt failed to reach the server, and as not stored when the server answered `malformed` or `unsupported`. A `put` given up on can still land later, since nothing in it expires.
- A conflict whose fetched blob [does not open](../docs/PROTOCOL.md#actions-get-and-put) under the Recovery key in memory routes setup to the join, and makes rotation report that another device rotated.

Cancel stops setup, join and Change Server while nothing is stored, and is off while a recovery-blob `put` is in flight.

**Setup** is the last onboarding step, so a new or wiped device starts from its synced notes, and stays in Settings for later; Settings is unavailable until onboarding ends. Locking or quitting during onboarding drops its remaining offers.

1. Take the server URL and the API key as hex, and `get` the blob. A server that already holds one routes to the join before any words are shown.
2. Generate the Content key and the Recovery key with a CSPRNG.
3. Show the 24 words hidden until revealed, every hidden word drawn as the same placeholder, then require three random words typed back. The revealed words cannot be selected, so they reach the pasteboard only through copying the words, which puts the numbered list on this device's pasteboard only, marked concealed and transient, and clears it on cancel, lock or quit unless something else was copied over it.
4. `put` the Content key encrypted under the Recovery key and, once that `put` has landed, store the Content key, API key, URL and pin in `meta`, and enable sync.

**Turn Off Sync and Change Server:** Turn Off Sync forgets only the server address and API key; the Content key, the pin, the last pulled `seq` with its mark, the first-push IDs and every note's version stay. Set Up Sync on such a library, or Change Server on a syncing one, checks the server: one that holds this library takes it back with no words; an empty one gets it under a new recovery phrase, with every note pushed as new and tombstones and first-push IDs dropped, while the old server keeps its sealed copy; one that holds another library is refused, since two libraries cannot merge, once this device has pulled a change to tell them apart by; before that, any server holding a recovery blob at or above the pin takes it back.

**A replaced API key:** Change Server with the same address takes the new key. The server holds this library when it answers under the new key with a recovery blob at or above the pin and, once this device has pulled, with the write its last pull ended on, by blinded ID at that `v` or later, whether or not it opens, so a write forged with a leaked key cannot block the change. A mistyped key, a server holding another library or one restored from an older backup leaves the old address, key and sync as they were.

**Rotation:** shows new words as setup does, then `put`s the Content key under the new Recovery key. After it reports that another device rotated, rotation asks for the current words; once the fetched blob opens under them and holds this library's Content key, the pin takes its `v` and rotation can run again.

**Restore and add-device** are a join: restore runs after setting up a library with a new [local DB password](#local-db-encryption), add-device from an unlocked library. A library that already holds a Content key refuses a join.

1. Take the server URL and the API key as setup does, then the 24 words, one per field. A paste splits at whitespace and commas, trims anything but letters from each word's ends, and fills the fields from the current one onward, or by number when every word follows its number, as in the copied list. Leaving a field lowercases an all-letter word and completes a prefix only one list word starts with. Words no list word starts with, and 24 list words that fail the checksum, are flagged. A lost API key is read from the server's [`api-key` file](../server/DESIGN.md#server-storage).
2. `get` the blob and open it with the Recovery key; nothing is stored unless it opens. A server that holds no blob routes back to setup.
3. Store the Content key, API key, URL and the `get`'s `v` as the pin in `meta`.
4. Sync from `seq = 0`. The library's existing notes are dirty, so they push.

## Sync

A sync runs 30 s after the last edit, delete, undone delete or import, when the app becomes or stops being active, after unlock, and on a manual sync, one at a time; requests made during a sync share the next one. It pushes every dirty note, as many per request as fit the [body limit](../docs/PROTOCOL.md#limits), and pulls until `more` is clear. Each response applies in one transaction with its `since`. Saves that fall due meanwhile wait, and an edit typed on a note a pull replaced moves to that note's copy. An acknowledged push never adds a note to the list.

A save carries the `v` its edit began at. `pulled` marks a row whose text a pull wrote; a save whose `v` no longer matches such a row lands as a new note, which the editor follows, so no save writes over pulled text.

An [`error`](../docs/PROTOCOL.md#response-error) fails the sync or setup step and is reported by its `reason`, `unsupported` as needing a newer app; an unknown `reason` reads as `fault`.

The server URL may be plain `http`, since everything past the URL is sealed. A stored address that is not an `http` or `https` URL with a host is reported as an error, and sync does not start. Requests carry only fixed headers, the same on every device, so nothing outside the envelope tells devices, builds or languages apart. Redirects are not followed, any status but 200 fails the request, nothing is cached, no cookie is kept, and a request gives up after 30 s without data or 120 s in all.

## Pull verification

Each pulled change, tombstones included, must pass three checks:

- It decrypts, and the `uuid` its content [begins with](../docs/PROTOCOL.md#content) re-derives the `blindedId` it arrived under.
- Its content decodes.
- Its `v` is not below the local `v`. Equal passes, since a device's own write comes back, and is not applied.

A change that fails a check is reported and not applied, so only a pulled tombstone that passes all three removes a local note. One that fails only to decode, over a `version` or `kind` this client does not know, is reported as written by a newer version. A pulled `v` below the local `v`, a push `conflict` carrying a `v` below it, a `put` `conflict` below the pin, or a `nextSeq` below the client's `since` means the server is behind the client: the client reports it and does not retry in a loop. A response whose `nextSeq` is below `since` is not applied at all, and `since` stays.

## Conflicts

Sync first flushes each note's pending save. A pulled change whose `v` is above the local `v`, for a note with unpushed edits, saves the unpushed text as a new note, with a new UUID, the unpushed `createdAt`, `updatedAt` and `ext`, and dirty at `v = 0`, and applies the pulled version, in one transaction; when the bodies match, no copy is made. A dirty local tombstone yields to a pulled edit, and a pulled tombstone over unpushed edits keeps the text as the copy. The open editor follows the copy. A dirty note at `v = u32::MAX`, which [no write can follow](../docs/PROTOCOL.md#notes), takes the same copy path without a pull: the copy takes the unpushed text, and the original keeps it locally and is marked clean; a dirty tombstone there is marked clean without a push.

A pulled change carrying the `writeId` of our own unacknowledged write is that write already stored after a lost response or a response that failed to commit: it counts as `accepted`, not a conflict. An `accepted` write sets the note's `v` and clears `dirty` only if the note was not saved after the write was sealed; otherwise the note stays dirty and pushes at the new `v + 1`. An `accepted` write whose note is no longer held becomes a dirty tombstone at that `v`, pushed in the same sync. Unacknowledged `writeId`s live in memory until a pull resolves each or sync stops, on lock, Turn Off Sync or Change Server; after that or a relaunch, a lost response takes the copy path, where matching bodies make no copy, and a pulled `v = 1` for a first-push ID in `meta` whose note is no longer held becomes the same tombstone.

A conflicted push stays dirty until its pull arrives. A note whose push `conflict` carried a `v` still above its local `v` once the sync reaches the head, because that version was skipped or never arrived, is reported. A failed sync retries at the next scheduled sync. A note whose payload would exceed the [note limit](../docs/PROTOCOL.md#limits) stays dirty and unpushed, and is reported.

## Exports

An export is the zip below, or, with a passphrase, this file, never zip's own encryption, which leaves names readable:

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
---
body
```

The fields come in this order and spelling only: `id` lowercase and hyphenated; `created` and `updated` as ISO 8601 in UTC with milliseconds on the proleptic Gregorian calendar, where year `0000` is 1 BC, and, for a year outside 0000–9999, a sign and the year zero-padded to six digits.

Import reads only this format, one import at a time, and refuses files over 512 MiB unread. A file that starts with `NNEXPORT1` opens with its passphrase, one that starts with `NNEXPORT` and then any other byte is refused as written by a newer version, and any other is read as the zip. Import finds entries through the central directory, which ends where the end record starts, and ignores bytes no entry covers before it. It checks every CRC-32, reads no meaning from names or times, and ignores versions, attributes, comments and extra fields of any kind, zip64's included. It refuses the whole archive over a method other than 0, a flag other than bit 11, an all-ones count, size or offset, a zip64 locator, a disk number other than 0, differing entry counts in the end record, a central directory its records do not fill exactly, a local header whose flags, method, time, date, CRC-32, sizes or name differ from its central record, an entry whose two sizes differ, overlapping entries, a name that is not UTF-8 or has NUL, `\`, or an empty, `.` or `..` path component, a file in any other spelling or not UTF-8, or a repeated `id`. It adds notes whose `id` the library does not hold, dirty at `v = 0`, in one transaction, and skips every `id` it holds, live or deleted.
