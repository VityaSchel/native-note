# Native Note Server Architecture

Native Note ships a server for sync and backup that serves as the source of truth. The server is written in Rust 1.95+.

Dependencies:

- `rusqlite` with `bundled`: SQLite, statically linked and version-pinned
- `ring` 0.17: AES-256-GCM, HKDF-SHA256, and `SystemRandom` as the only CSPRNG

Rust 1.95 std has no AEAD, HKDF, SQLite or stable CSPRNG. With `ring` the server's tree is 20 crates on Linux, against 43 with RustCrypto's `aes-gcm`, `hkdf`, `sha2` and `getrandom`, and needs no compiler beyond the one bundled SQLite already needs; the [vector generator](../spec/README.md) keeps RustCrypto, so the vectors cross-check two implementations.

`native-note-core` depends on `ring` alone. Test and fuzz dependencies never reach the binary:

- `serde_json`: std has no JSON parser, and the core's tests replay [spec/vectors](../spec/README.md), which are JSON
- `proptest`: generated inputs for the property tests
- `libfuzzer-sys`: runs the fuzz targets, which sit in their own workspace and lockfile under `native-note-core/fuzz`

## Server core

`server/` is a Cargo workspace. `native-note-core` is the request path as pure logic: no sockets, files, clock, randomness, logging or SQLite. `native-note-server` adds those and the binary.

- The core runs inside the caller's [transaction](#server-storage) and never commits or rolls back; a fault it returns means roll back and answer `error`.
- The response nonce is drawn before the transaction begins, so a failed draw answers `500` with nothing stored. `seal` refuses a response nonce equal to the request nonce, which also answers `500`.
- The core assigns [`seq`](../docs/PROTOCOL.md#ordering) and storage only persists it: a `sync` reads the latest `seq` once and stamps accepted writes in submission order. A `seq` past `u64::MAX` answers `error`.
- Storage yields changes one row per call, so a pull never loads more than one change past the response budget.
- A sync response takes changes until the next one would pass the [body limit](../docs/PROTOCOL.md#limits). When not even the first pending change fits, the request answers `error`, since [`more` needs a change](../docs/PROTOCOL.md#action-sync).
- `Envelope`, `Opened` and `Reply`, which hold whole sealed or padded frames, have no `Debug`.
- The HTTP request head is parsed in the core, so it falls under the coverage gate and a fuzz target.
- The non-test build forbids panicking APIs and unchecked arithmetic by lint; [lib.rs](native-note-core/src/lib.rs) and [clippy.toml](native-note-core/clippy.toml) list the bans.
- Every line, branch and region of `native-note-core/src` outside its `tests.rs` files runs under a deterministic test, property tests excluded, measured with the nightly pinned in [server-coverage.sh](../.forgejo/scripts/server-coverage.sh).

## Server API

HTTP layer is hand-rolled on `std::net::TcpListener` — ~300 lines over 2 direct dependencies vs `axum` (~200 crates) or `hyper`+`tokio` (~50-60 crates). Blocking:

- One listener on the given address. `[::]` also accepts IPv4 where the host default `net.ipv6.bindv6only=0` allows it, since std cannot set `IPV6_V6ONLY`.
- A fixed number of threads each block in `accept` on that listener; the listen backlog is the only queue.
- Framing, route and statuses per [API](../docs/PROTOCOL.md#api): no chunked decoding and no keep-alive state machine. A request rejected before unsealing writes no log line.
- Caps on the request line and headers per [API](../docs/PROTOCOL.md#api) and on [body size](../docs/PROTOCOL.md#limits), enforced before allocating.
- Read and write timeouts on every socket operation, and a deadline per connection counted from accept.
- No devices, sessions, per-caller state or rate limits; throttling belongs in a reverse proxy.

## Server storage

The [API key](../docs/PROTOCOL.md#api-key) is always `<data directory>/api-key`, mode `0600`, and the loader parses it as that section says. When the file is absent, the server generates a key and writes it to a temporary file at `0600`, fsyncs it, renames it into place and fsyncs the directory. The key is never printed; that run logs only the file's path.

Secrets are wrapped in `Secret<T>`, whose `Debug` prints `[redacted]` and which has no `PartialEq`. No zeroize and no constant-time helper: the GCM tag check inside `ring` is the only comparison of secret data.

SQLite: WAL, `synchronous=FULL`, one connection shared by every thread behind a mutex, `busy_timeout` set so an operator's `sqlite3 .backup` does not fail requests. A thread takes the mutex after the request is read and unsealed and releases it before the response is written.

One transaction per request. The server builds the response inside it, `sync` changes included, and commits before sealing. A fault inside it rolls it back and gets [`error`](../docs/PROTOCOL.md#response-error); only a failure to seal, answered `500`, can follow a commit. Failures after unsealing are logged by category, not counted.

Crash-only: no signal handlers; SIGTERM and SIGINT end the process at once.

Boot runs `PRAGMA integrity_check`; a failure logs, exits non-zero and leaves the database as it is. The server takes no snapshots and never restores. Operators back up with `sqlite3 .backup` or `VACUUM INTO`, never `cp` of a live WAL database. A backup holds the database only, not the key, so it cannot decrypt traffic or forge requests.

### `note` table

```sql
CREATE TABLE note (
    blindedId BLOB    PRIMARY KEY NOT NULL,
    v         INTEGER NOT NULL,
    seq       INTEGER NOT NULL UNIQUE,
    writeId   BLOB    NOT NULL,
    payload   BLOB    NOT NULL
);
```

`seq` is not the rowid: it is reassigned on every write, and plain rowid reuses freed values.

### `meta` table

```sql
CREATE TABLE meta (k TEXT PRIMARY KEY NOT NULL, n INTEGER NOT NULL) STRICT;
```

| `k`   | description                                          |
| ----- | ---------------------------------------------------- |
| `seq` | The [sequence](../docs/PROTOCOL.md#ordering) counter |

### `content_key` table

```sql
CREATE TABLE content_key (
    id   INTEGER PRIMARY KEY CHECK (id = 1),
    v    INTEGER NOT NULL,
    blob BLOB    NOT NULL
) STRICT;
```

The encrypted [Content key](../docs/PROTOCOL.md#recovery-key).

`CHECK (id = 1)` enforces singleton schema.

## Server config

```
native-note-server <listen address> <data directory>
```

Both arguments are required and positional, read with `std::env::args`. No flags, config file or environment variables.

The systemd unit runs `/usr/local/bin/native-note-server` (mode `0755`, owner `root:root`) as an unprivileged user, passes `/var/lib/native-note-server/` (mode `0700`, owned by that user) as the data directory, and sets `LimitCORE=0`.

Health checks `POST /` and expect `400`, or open a TCP connection.
