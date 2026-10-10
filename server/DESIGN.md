# Native Note Server Architecture

Native Note ships a server for sync and backup that serves as the source of truth. The server is written in Rust 1.95+.

Dependencies:

- `rusqlite` with `bundled`: SQLite, statically linked and version-pinned
- `ring` 0.17: AES-256-GCM, HKDF-SHA256, and `SystemRandom` as the only CSPRNG

Rust 1.95 std has no AEAD, HKDF, SQLite or stable CSPRNG. With `ring` the server's tree is 20 crates on Linux, against 43 with RustCrypto's `aes-gcm`, `hkdf`, `sha2` and `getrandom`, and needs no compiler beyond the one bundled SQLite already needs; the [vector generator](../spec/README.md) keeps RustCrypto, so the vectors cross-check two implementations.

## Server API

HTTP layer is hand-rolled on `std::net::TcpListener` — ~300 lines over 2 direct dependencies vs `axum` (~200 crates) or `hyper`+`tokio` (~50-60 crates). Blocking:

- One listener on the given address. `[::]` also accepts IPv4 where the host default `net.ipv6.bindv6only=0` allows it, since std cannot set `IPV6_V6ONLY`.
- A fixed number of threads each block in `accept` on that listener; the listen backlog is the only queue.
- `Content-Length` required, `Transfer-Encoding` rejected — no chunked decoding.
- `Connection: close` — no keep-alive state machine.
- Caps on request line, header count, header bytes, and [body size](../docs/PROTOCOL.md#limits), enforced before allocating.
- Read and write timeouts on every socket operation, and a deadline per connection counted from accept.
- Route and statuses per [API](../docs/PROTOCOL.md#api). A request rejected before unsealing writes no log line.
- No devices, sessions, per-caller state or rate limits; throttling belongs in a reverse proxy.

## Server storage

The [API key](../docs/PROTOCOL.md#api-key) is always `<data directory>/api-key`, mode `0600`. The loader trims surrounding whitespace and rejects anything but 64 lowercase hex characters. When the file is absent, the server generates a key and writes it to a temporary file at `0600`, fsyncs it, renames it into place and fsyncs the directory. The key is never printed; that run logs only the file's path.

Secrets are wrapped in `Secret<T>`, whose `Debug` prints `[redacted]`. No zeroize and no constant-time helper: the GCM tag check inside `ring` is the only comparison of secret data.

SQLite: WAL, `synchronous=FULL`, one connection shared by every thread behind a mutex, `busy_timeout` set so an operator's `sqlite3 .backup` does not fail requests. A thread takes the mutex after the request is read and unsealed and releases it before the response is written.

One transaction per request. The server builds the response inside it, `sync` changes included, and commits before sealing. A fault inside it rolls it back and gets [`error`](../docs/PROTOCOL.md#response-error); only a failure to seal, answered `500`, can follow a commit. Failures after unsealing are logged by category, not counted.

Crash-only: no signal handlers; SIGTERM and SIGINT end the process at once.

Boot runs `PRAGMA integrity_check`; a failure logs, exits non-zero and leaves the database as it is. The server takes no snapshots and never restores. Operators back up with `sqlite3 .backup` or `VACUUM INTO`, never `cp` of a live WAL database. A backup holds the database only, not the key, so it cannot decrypt traffic or forge requests.

### `note` table

Notes entries.

```sql
CREATE TABLE note (
    blindedId BLOB    PRIMARY KEY NOT NULL,
    v         INTEGER NOT NULL,
    seq       INTEGER NOT NULL UNIQUE,
    writeId   BLOB    NOT NULL,
    payload   BLOB    NOT NULL
);
```

The `seq` counter is incremented in the same DB transaction as the write. It is not the rowid: `seq` is reassigned on every write, and plain rowid reuses freed values.

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
