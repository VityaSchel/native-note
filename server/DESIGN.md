# Native Note Server Architecture

The sync server is the source of truth.

Dependencies:

- `rusqlite` with `bundled`: SQLite, statically linked and version-pinned
- `ring` 0.17: AES-256-GCM, HKDF-SHA256, and `SystemRandom` as the only CSPRNG

Rust 1.95 std has no AEAD, HKDF, SQLite or stable CSPRNG. `ring` keeps the server's tree at 18 crates on Linux, its own two included, against 43 with RustCrypto's `aes-gcm`, `hkdf`, `sha2` and `getrandom`, and needs no compiler beyond the one bundled SQLite needs. The [vector generator](../spec/README.md) keeps RustCrypto, so the vectors cross-check two implementations.

`native-note-core` depends on `ring` alone. Test and fuzz dependencies, which never reach the binary:

- `serde_json`: the core's tests replay [spec/vectors](../spec/README.md), which are JSON
- `proptest`: property tests
- `libfuzzer-sys`: the fuzz targets, in their own workspace and lockfile under `native-note-core/fuzz`, where `frame` and `envelope` check decoding against the testkit's encoder; its NCSA license is the one exception in [deny.toml](../deny.toml), and it alone needs a C++ compiler
- `native-note-testkit`: the workspace's test client, corpus, reference model and device sessions, so the same sessions run against the core in memory and the server over HTTP

## Server core

`server/` is a Cargo workspace. `native-note-core` is the request path as pure logic: no sockets, files, clock, randomness, logging or SQLite. `native-note-server` adds those and the binary.

- The core runs inside the caller's [transaction](#server-storage) and never commits or rolls back; a fault it returns means roll back and answer `error`.
- The response nonce is drawn before the transaction begins, so a failed draw answers `500` with nothing stored. `seal` refuses a response nonce equal to the request nonce, which also answers `500`.
- The core assigns [`seq`](../docs/PROTOCOL.md#ordering) and storage only persists it: a `sync` reads the latest `seq` once and stamps accepted writes in submission order. A `seq` past `u64::MAX` answers `error`.
- Storage yields changes one row per call, so a pull never loads more than one change past the response budget.
- A sync response takes changes until the next one would pass the [body limit](../docs/PROTOCOL.md#limits). When not even the first pending change fits, the request answers `error`, since [`more` needs a change](../docs/PROTOCOL.md#action-sync).
- `Envelope`, `Opened` and `Reply`, which hold whole sealed or padded frames, have no `Debug`.
- The HTTP request head is parsed in the core, under the coverage gate and a fuzz target.
- The non-test builds of both crates forbid panicking APIs and unchecked arithmetic by lint; [lib.rs](native-note-core/src/lib.rs) and [clippy.toml](clippy.toml) list the bans.
- Coverage gate: every line, branch and region of `native-note-core/src` outside its tests runs under a deterministic test, property tests excluded, and at least 90% of `native-note-server/src`'s, measured with the nightly pinned in [server-coverage.sh](../.forgejo/scripts/server-coverage.sh).

## Server API

The HTTP layer is hand-rolled and blocking on `std::net::TcpListener`, adding no dependency.

- One listener on the given address. `[::]` also accepts IPv4 where the host default `net.ipv6.bindv6only=0` allows it, since std cannot set `IPV6_V6ONLY`.
- 8 threads each block in `accept` on that listener; the listen backlog is the only queue. A request holds about 10 MiB at its peak, so 8 bound the server near 80 MiB.
- Framing, route and statuses per [API](../docs/PROTOCOL.md#api): no chunked decoding and no keep-alive. A request rejected before unsealing writes no log line.
- Caps on the request line and headers per [API](../docs/PROTOCOL.md#api) and on [body size](../docs/PROTOCOL.md#limits), enforced before allocating.
- Each socket read and write times out after 10 s, and a connection ends 60 s after accept, the reply included.
- The body is exactly `Content-Length` bytes; anything after them is ignored.
- After a `400` or `413` the server reads and discards what the client still sends until it stops or the deadline passes, so closing does not reset the refusal before the client reads it.
- No devices, sessions, per-caller state or rate limits; throttling belongs in a reverse proxy.

## Server storage

The [API key](../docs/PROTOCOL.md#api-key) is always `<data directory>/api-key`, mode `0600`. When the file is absent, the server generates a key, writes it to a temporary file at `0600`, fsyncs it, renames it into place and fsyncs the directory. The key is never printed; that run logs only the file's path. A missing data directory is created at `0700`; an existing one keeps its mode.

Secrets are wrapped in `Secret<T>`, whose `Debug` prints `[redacted]` and which has no `PartialEq`. No zeroize and no constant-time helper: the GCM tag check inside `ring` is the only comparison of secret data.

SQLite: `<data directory>/native-note.sqlite`, created at `0600`, which its WAL and shared-memory files inherit. WAL, `synchronous=FULL`, one connection shared by every thread behind a mutex, `busy_timeout` of 5 s so an operator's `sqlite3 .backup` does not fail requests. A thread holds the mutex from after the request is read and unsealed until before the response is written.

One `BEGIN IMMEDIATE` transaction per request. The server builds the response inside it, `sync` changes included, and commits before sealing. A fault inside it, or a failed commit, rolls it back and gets [`error`](../docs/PROTOCOL.md#response-error); only a failure to seal, answered `500`, or to send can follow a commit. Failures after unsealing are logged by category, not counted.

Logging is one `key=value` line per event on stderr, which the journal timestamps. Events carry only addresses, the operator's paths and fixed categories: SQLite errors by result code, I/O errors by kind, decode errors by variant.

Crash-only: no signal handlers; SIGTERM and SIGINT end the process at once.

Boot runs `PRAGMA integrity_check` before writing anything; a failure logs, exits non-zero and leaves the database as it is. Migrations are forward-only, and `PRAGMA user_version` counts those applied; a database from a newer server is refused the same way. The server takes no snapshots and never restores; operators [back up](../docs/guides/setup-sync-server.md#backup) the database, which holds no key, so a backup can neither decrypt traffic nor forge requests.

### `note` table

```sql
CREATE TABLE note (
    blindedId BLOB    PRIMARY KEY NOT NULL CHECK (length(blindedId) = 16),
    v         INTEGER NOT NULL CHECK (v > 0),
    seq       INTEGER NOT NULL UNIQUE CHECK (seq > 0),
    writeId   BLOB    NOT NULL CHECK (length(writeId) = 16),
    payload   BLOB    NOT NULL
) STRICT;
```

`seq` is reassigned on every write, so it is not the rowid, which reuses freed values. The latest [`seq`](../docs/PROTOCOL.md#ordering) is `MAX(seq)`, read through its unique index; notes are never deleted, so it never goes back, and no counter is stored. SQLite holds `seq` up to `i64::MAX`, and a write past it answers `error`.

### `content_key` table

The encrypted [Content key](../docs/PROTOCOL.md#recovery-key), a single row:

```sql
CREATE TABLE content_key (
    id   INTEGER PRIMARY KEY CHECK (id = 1),
    v    INTEGER NOT NULL CHECK (v > 0),
    blob BLOB    NOT NULL
) STRICT;
```

## Server config

```
native-note-server <listen address> <data directory>
```

Both arguments are required and positional, read with `std::env::args_os`. No flags, config file or environment variables. Wrong arguments exit `2`, any other startup failure `1`.

The [systemd unit](native-note-server.service) runs `/usr/local/bin/native-note-server` (mode `0755`, owner `root:root`) as a `DynamicUser`, passes `/var/lib/native-note-server/` (its `StateDirectory`, mode `0700`) as the data directory, sets `LimitCORE=0`, and sandboxes the service to an exposure of 1.1 in `systemd-analyze security`.

## Server release

[server-release.sh](../.forgejo/scripts/server-release.sh) builds a clean checkout into static `x86_64` and `aarch64` musl binaries with the toolchain pinned in [rust-toolchain.toml](../rust-toolchain.toml), the pinned `zig` as the C compiler and `rust-lld` as the linker, remapping every local path, and packs each with the systemd unit into a tarball with fixed owner, modes, order and time, in `releases/`, printing its SHA-256. Two builds on the same build host produce identical tarballs; builds on different hosts do not, since Cargo hashes `rustc -vV`, which names the host, into every crate.
