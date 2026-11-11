# Sync server

One static Linux binary that stores sealed notes in SQLite. Server works over bare IPv4, bare IPv6 or a domain name, with or without HTTPS.

## Install

There is no release yet. Build the tarballs per [CONTRIBUTING.md](../../CONTRIBUTING.md#server); they land in `releases/`, one for `x86_64` and one for `aarch64` Linux, each holding the static binary and [the systemd unit](../../server/native-note-server.service). On the host, unpack the one for its architecture:

```sh
tar -xzf native-note-server-aarch64-unknown-linux-musl.tar.gz
sudo install -m 0755 -o root -g root native-note-server /usr/local/bin/native-note-server
sudo install -m 0644 native-note-server.service /etc/systemd/system/
sudo systemctl enable --now native-note-server
```

The unit listens on `[::]:8080` and keeps its data in `/var/lib/native-note-server/`. Without systemd, pass the listen address and the data directory, in that order; wrong arguments exit `2` and any other startup failure `1`:

```sh
native-note-server [::]:8080 /srv/native-note
```

> [!TIP]
> If you choose to use a reverse proxy, configure it to accept HTTP/1.1 and request bodies of at least 2 MiB + 28 B
> For example, in nginx set `proxy_http_version 1.1;` and `client_max_body_size 3m;`

```sh
sudo systemctl edit native-note-server
```

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/native-note-server [::1]:8080 /var/lib/native-note-server
```

```sh
sudo systemctl restart native-note-server
```

## Connect a client

The first start writes the API key to `api-key` file in the data directory.

```sh
sudo cat /var/lib/native-note-server/api-key
```

In Native Note, open Settings, choose Set Up Sync…, and enter the server's address and the API key.

To rotate the API key, remove the `api-key` file and restart the server. Then update the API key in each Native Note client.

## Health checks

`POST /` answers `400` while the server is up, and opening a TCP connection to its port works too:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://notes.example:8080/
```

`journalctl -u native-note-server` shows `event=listening` on start and `event=request_failed` for each request that fails after it is unsealed; one refused before that, such as one sealed with the wrong API key, logs nothing. Startup checks the database's integrity; a failure logs `event=startup_failed`, exits `1` and leaves the database untouched.

## Backup

Never copy the live database with `cp`: it runs in WAL mode, so a copy can miss or tear recent writes. Use SQLite's online backup, while the server runs. The server links SQLite statically and ships no `sqlite3`, so install the distribution's (`sudo apt-get install sqlite3`), then either:

```sh
sudo install -d -m 0700 /backup
sudo sqlite3 /var/lib/native-note-server/native-note.sqlite ".backup '/backup/native-note.sqlite'"
sudo sqlite3 /var/lib/native-note-server/native-note.sqlite "VACUUM INTO '/backup/native-note.sqlite'"
```

A backup holds sealed notes only, not the API key. Keep a copy of `api-key` apart from it: a server restored with another key refuses every Mac.

## Restore

```sh
sudo systemctl stop native-note-server
sudo rm -f /var/lib/native-note-server/native-note.sqlite /var/lib/native-note-server/native-note.sqlite-wal /var/lib/native-note-server/native-note.sqlite-shm
sudo install -m 0600 /backup/native-note.sqlite /var/lib/native-note-server/native-note.sqlite
sudo chown --reference=/var/lib/native-note-server /var/lib/native-note-server/native-note.sqlite
sudo systemctl start native-note-server
```

The `chown` gives the file to the service's user; without it, startup fails with `cause=io:PermissionDenied`.

A Mac that synced after the backup was taken reports the server as behind it and keeps its notes; bringing it back in step with a restored server is [not supported yet](../ROADMAP.md). A Mac set up after the restore gets the backup's notes.

## Losing everything

Only the 24-word recovery phrase, the Macs holding the library and its exports can read the notes. Losing all of them loses the notes for good: the server, its backups and its operator hold sealed data only.
