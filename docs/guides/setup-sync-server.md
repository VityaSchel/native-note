# Getting started with Native Note server

Native Note server is a static binary that stores sealed notes in SQLite. It works over bare IPv4, bare IPv6 or a domain name, with or without HTTPS.

## Install

1. Download the binary for the host:

- Linux x86_64: [native-note-server-v0.1.0-linux-x86_64](https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-server-v0.1.0-linux-x86_64)
- Linux aarch64 (Raspberry Pi 3 or later on a 64-bit OS): [native-note-server-v0.1.0-linux-aarch64](https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-server-v0.1.0-linux-aarch64)
- Linux armv7 (Raspberry Pi 2 or later on a 32-bit OS): [native-note-server-v0.1.0-linux-armv7](https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-server-v0.1.0-linux-armv7)
- Linux armv6 (Raspberry Pi 1, Zero or Zero W): [native-note-server-v0.1.0-linux-armv6](https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-server-v0.1.0-linux-armv6)

Or [build from source](../../BUILD.md#sync-server).

2. Download [the systemd unit](https://git.hloth.dev/hloth/native-note/raw/tag/v0.1.0/contrib/native-note-server.service)

```sh
sudo install -m 0755 -o root -g root native-note-server-v0.1.0-linux-<arch> /usr/local/bin/native-note-server
sudo install -m 0644 native-note-server.service /etc/systemd/system/
sudo systemctl enable --now native-note-server
```

The unit listens on `[::]:8080` and keeps its data in `/var/lib/native-note-server/`. Without systemd, pass the listen address and the data directory:

```sh
native-note-server '[::]:8080' /srv/native-note
```

Behind a reverse proxy, which must speak HTTP/1.1 to the server and accept request bodies of at least 2 MiB + 28 B (in nginx, `proxy_http_version 1.1;` and `client_max_body_size 3m;`), bind the server to loopback with `sudo systemctl edit native-note-server`, then restart it:

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/native-note-server [::1]:8080 /var/lib/native-note-server
```

Or serve it on a Unix socket, with `proxy_pass http://unix:/run/native-note-server/native-note.sock;` in nginx:

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/native-note-server /run/native-note-server/native-note.sock /var/lib/native-note-server
RuntimeDirectory=native-note-server
RestrictAddressFamilies=
RestrictAddressFamilies=AF_UNIX
PrivateNetwork=yes
```

## Connect a client

The first start writes the API key to the `api-key` file in the data directory:

```sh
sudo cat /var/lib/native-note-server/api-key
```

In Native Note, choose Set Up after the unlock password, or Set Up Sync… in Settings later, and enter the server's address and this key.

To replace the API key, remove the `api-key` file and restart the server, then on each Mac choose Change Server… in Settings, keep the address and enter the new key.

## Health checks

`POST /` answers `400` while the server is up; a TCP connection to its port works too:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://notes.example:8080/
curl -s -o /dev/null -w '%{http_code}\n' -X POST --unix-socket /run/native-note-server/native-note.sock http://localhost/
```

`journalctl -u native-note-server` shows `event=listening` on start and `event=request_failed` for each request that fails after it is unsealed; one sealed with the wrong API key logs nothing. Startup checks the database's integrity; a failure logs `event=startup_failed`, exits `1` and leaves the database untouched.

## Backup

Back up the live database with SQLite's online backup, never `cp`, using the distribution's `sqlite3`:

```sh
sudo install -d -m 0700 /backup
sudo sqlite3 /var/lib/native-note-server/native-note.sqlite ".backup '/backup/native-note.sqlite'"
```

`VACUUM INTO '/backup/native-note.sqlite'` works too. A backup holds sealed notes, not the API key or the `seq` file; keep a copy of `api-key` apart from it, since a server restored with another key refuses every Mac.

## Restore

```sh
sudo systemctl stop native-note-server
sudo rm -f /var/lib/native-note-server/native-note.sqlite /var/lib/native-note-server/native-note.sqlite-wal /var/lib/native-note-server/native-note.sqlite-shm
sudo install -m 0600 /backup/native-note.sqlite /var/lib/native-note-server/native-note.sqlite
sudo chown --reference=/var/lib/native-note-server /var/lib/native-note-server/native-note.sqlite
sudo systemctl start native-note-server
```

The `seq` file is not restored with the database: kept in the data directory, or missing on a new host, it makes the server number new writes above every `seq` it handed out. A Mac that synced after the backup was taken keeps its notes and gets every write made after the restore; it reports the server as behind it on meeting a note older there than its own, and does not converge with the restored server yet ([#9](https://git.hloth.dev/hloth/native-note/issues/9)). A Mac set up after the restore gets the backup's notes.
