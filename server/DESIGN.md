# Native Note Server Architecture

Native Note ships a server for sync and backup that serves as the source of truth. The server is written in Rust 1.95+.

Default locations:

- Binary: `/usr/local/bin/native-note-server` (mode: `0755`, owner: `root:root`, execute as: *non-sudo user*)
- Config directory: `/etc/native-note-server/` (mode: `0755`, owner: `root:root`)
- Config file: `/etc/native-note-server/config.toml` (mode: `0644`, owner: `root:root`)
- Data directory: `/var/lib/native-note-server/` (mode: `0700`, owner: `*non-sudo user*:root`)
- API key (by default, configurable): `/var/lib/native-note-server/api-key` (mode: `0600`, owner: `*non-sudo user*:root`)

Dependencies:

- `rusqlite` (bundled SQLite, statically links a pinned SQLite)
- `getrandom`

## Implementation details

- CSPRNG uses the `getrandom` crate — `getrandom(2)` on Linux, `getentropy(2)` on macOS and BSD, `BCryptGenRandom` on Windows.

## Server API

HTTP layer is hand-rolled on `std::net::TcpListener` — ~300 lines over 2 direct dependencies vs `axum` (~200 crates) or `hyper`+`tokio` (~50-60 crates). Blocking, bounded thread pool:

- `Content-Length` required, `Transfer-Encoding` rejected — no chunked decoding.
- `Connection: close` — no keep-alive state machine.
- Caps on request line, header count, header bytes, and body size, enforced before allocating.
- Read and write timeouts on every socket.
- One dual-stack listener on `[::]` with `IPV6_V6ONLY=0`.

## Server storage

The server holds [API key](../docs/PROTOCOL.md#api-key) in a separate private file, encoded in lowercase hex, leading/trailing whitespaces trimmed when loading and on write.

Server DB is SQLite via `rusqlite` with `bundled` — statically linked, version-pinned, reproducible. WAL, `synchronous=FULL`, `PRAGMA integrity_check` on boot with restore from the last `VACUUM INTO` snapshot, one transaction per write, every failure counted by category.

Backups: `VACUUM INTO` copies the database only and excludes the key, so a database backup cannot decrypt traffic or forge requests.

Server does not track and store devices or sessions.

### `notes` table

Notes entries.

```sql
CREATE TABLE note (
    blindedId BLOB    PRIMARY KEY NOT NULL,
    v         INTEGER NOT NULL,
    seq       INTEGER NOT NULL UNIQUE,
    writeId   BLOB    NOT NULL,
    deleted   INTEGER NOT NULL,
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

TOML file, default location: `/etc/native-note-server/config.toml` (mode: `0644`, owner: `root:root`)

| Key                   | Default                                 | Description                                  |
| --------------------- | --------------------------------------- | -------------------------------------------- |
| `api_key_path`        | `"/var/lib/native-note-server/api-key"` | API key location                             |
| `note_max_size`       | `"1 MB"`                                | Encrypted note payload max size              |
| `body_max_size`       | `"2 MB"`                                | Request payload max size                     |
| `rate_per_minute`     | `60`                                    | Requests per minute, per source address      |
| `unopened_per_minute` | `10`                                    | Frames the API key does not open, per source |
| `store_max_bytes`     | unset (available disk space)            | Total stored payload bytes                   |

Template:

```toml
api_key_path = "/var/lib/native-note-server/api-key"
note_max_size = "1 MB"
body_max_size = "2 MB"
rate_per_minute = 60
unopened_per_minute = 10
```
