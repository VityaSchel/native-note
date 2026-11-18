# Contributing to Native Note

## Layout

```
docs/              cross-cutting design, protocol, user guides
spec/              conformance vectors, their generator, BIP39 wordlists
server/            Rust server workspace, docs in its root
contrib/           the server's systemd unit
clients/           shared client design, one directory per platform
clients/macos/     Xcode project, docs in its root
devtools/          development-only tools, never shipped
```

## Checks

CI runs repository hygiene, the link check and the Rust checks below with `--locked`, and the server tests on arm64, armv7 and ARMv6 under qemu, on every pull request ([checks.yml](.forgejo/workflows/checks.yml)), the supply-chain checks nightly ([audit.yml](.forgejo/workflows/audit.yml)), and builds the server binaries for a release tag it is dispatched with ([release.yml](.forgejo/workflows/release.yml)).

### Conformance vectors

```sh
cd spec/generator
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo run --bin gen-vectors
../../.forgejo/scripts/rust-coverage.sh
```

### Server

```sh
cd server
cargo fmt --check
rustfmt --check --edition 2024 native-note-core/fuzz/fuzz_targets/*.rs
cargo clippy --all-targets -- -D warnings
(cd native-note-core/fuzz && cargo clippy --all-targets -- -D warnings && cargo build)
cargo test
../.forgejo/scripts/server-coverage.sh
```

- Property tests live in modules named `props`, which the [coverage gate](server/DESIGN.md#server-core) skips.
- Fuzzing is manual: run `frame`, `envelope` and `http` overnight with `cargo-fuzz` 0.13.2 on the nightly `server-coverage.sh` pins, and keep each minimized finding as a regression test in `tests/suite`.
- Release binaries: `.forgejo/scripts/server-release.sh`, per [BUILD.md](BUILD.md#sync-server). A release starts by pushing a signed tag and dispatching [release.yml](.forgejo/workflows/release.yml) with it, which offers the binaries both cloud builds agree on as the `native-note-server-<tag>` artifact. `.forgejo/scripts/release-sign.sh <tag> <artifact>` then rebuilds them on this Mac, refuses any that differ, and stages them in `releases/<tag>/` with the macOS zips, `SHA256SUMS` and its signature, ready to upload to a release created by hand on the tag.

### Supply chain

In `server/`, `server/native-note-core/fuzz/` and `spec/generator/`, with the versions [audit.yml](.forgejo/workflows/audit.yml) pins:

```sh
cargo deny --config <repository>/deny.toml check
cargo audit --deny warnings
```

### macOS client

Xcode 26.2 or newer on macOS 26.0. Touch ID needs a team-signed build: put these in the git-ignored `clients/macos/Local.xcconfig` and pass `-allowProvisioningUpdates` to `xcodebuild`:

```
DEVELOPMENT_TEAM = <your team ID>
NATIVE_NOTE_ENTITLEMENTS = NativeNote.entitlements
```

```sh
cd clients/macos
native-note-kit/Scripts/sqlcipher-amalgamation.sh
xcodebuild build -project native-note.xcodeproj -scheme native-note -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build -allowProvisioningUpdates
ditto "build/Build/Products/Release/Native Note.app" "/Applications/Native Note.app"
xcodebuild test -project native-note.xcodeproj -scheme native-note -destination 'platform=macOS'
(cd native-note-kit && swift test)
```

The package's sync tests build and run the server. Hosted coverage needs `ENABLE_APP_SANDBOX=NO`. A release, one notarized zip per architecture in `releases/`, built from a clean tree with the version set in the project, needs Xcode 27A266a, the team's Developer ID certificate and provisioning profile and the `native-note` notarytool profile: `.forgejo/scripts/macos-release.sh [<tag>]`. An App Store package, one universal `.pkg` in `releases/` for Transporter, needs an Apple Distribution and a Mac Installer Distribution certificate and a Mac App Store provisioning profile instead: `.forgejo/scripts/macos-appstore.sh [<tag>]`. Building without signing and checking published zips: [BUILD.md](BUILD.md#macos-app).

- Every feature gets unit tests and headless end-to-end tests, which run real Argon2 and the Secure Enclave on the generated `RealisticCorpus` library and relaunch through a fresh `AppModel`.
- Tests never present windows, sheets or alerts; host views in `OffscreenWindow`.
- Power loss and the [force-quit budget](clients/DESIGN.md#local-db): [devtools/macos-power-loss](devtools/macos-power-loss/README.md).

## Rules

- A spec change regenerates the vectors in the same commit; `cargo test` in `spec/generator` fails on a stale or stray vector file. A new vector file is listed in the server's `tests/suite/support/vectors.rs` and the client's `VectorFile`.
- No floating dependencies: pin an exact version backed by a lockfile checksum, a commit revision or a content hash.
- A new server dependency needs a written justification in [server/DESIGN.md](server/DESIGN.md).
- Every claim in the README and docs matches the code; a mismatch is a defect.

## Naming

| Context                            | Form                                            | Examples                                                                          |
| ---------------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------- |
| Human-readable                     | `Native Note`                                   | window title, README, release notes                                               |
| Paths, URLs, identifiers           | `native-note`                                   | directories, repo, crates, Xcode targets                                          |
| PascalCase languages, mainly Swift | `NativeNote`                                    | type names, the files holding them, Swift modules (`NativeNote`, `NativeNoteKit`) |
| Where a hyphen is not allowed      | `nativenote` or `native_note`, decided per case | bundle IDs, Rust crate names in code                                              |

Never `nativeNote`. The bundle ID is `dev.hloth.nativenote` on every platform, since Android package segments disallow hyphens.

## Style

- Tabs for indentation, four-wide, where possible.
- Comment only what the code cannot say, with a spec citation or reference link.
- Split files past roughly 300–400 lines.
- Rust: `rustfmt` with hard tabs. Clippy warnings are errors.
- Swift: no `try!` outside tests.
- Dates as `YYYY-MM-DD`. US English. Metric units.

## Security

Read [docs/ARCHITECTURE.md § Threat model](docs/ARCHITECTURE.md#threat-model) before touching crypto, key storage or the request path. Never log secrets or plaintext: server key material stays in [`Secret<T>`](server/DESIGN.md#server-storage), Swift key material in `SymmetricKey`. Report vulnerabilities per [SECURITY.md](SECURITY.md).
