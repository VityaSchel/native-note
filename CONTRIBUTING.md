# Contributing

## Layout

```
docs/              cross-cutting design, sync protocol, roadmap
spec/vectors/      language-neutral conformance vectors
spec/generator/    Rust tool that generates and verifies them
spec/wordlists/    BIP39 wordlists, pinned by hash
server/            Rust server workspace, docs in its root
clients/           shared client design, one directory per platform
clients/macos/     Xcode project, docs in its root
devtools/          development-only tools, never shipped
```

## Build and test

Every pull request runs [.forgejo/workflows/checks.yml](.forgejo/workflows/checks.yml) on Linux:
repository hygiene, documentation links, and the Rust commands below with `--locked` added.
Supply-chain checks run nightly in [.forgejo/workflows/audit.yml](.forgejo/workflows/audit.yml).

### Conformance vectors

Format and per-file contents: [spec/README.md](spec/README.md).

```sh
cd spec/generator
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test                                # verify the generator reproduces every vector
cargo run --bin gen-vectors               # regenerate after an intentional protocol change
../../.forgejo/scripts/rust-coverage.sh   # line coverage of src/, excluding src/bin
```

The generator is deterministic: salts, nonces, and keys are fixed. Regenerating without a protocol change must produce no diff.

Every line of `src/` outside `src/bin` must run under test; the coverage script lists any that do not.

Supply chain:

```sh
cargo install --locked cargo-deny@0.20.2 cargo-audit@0.22.2   # versions pinned in audit.yml
cargo deny --config ../../deny.toml check
cargo audit --deny warnings
```

### Server

Design: [server/DESIGN.md](server/DESIGN.md). Only `native-note-core`, the request path without IO, exists so far.

```sh
cd server
cargo fmt --check
rustfmt --check --edition 2024 native-note-core/fuzz/fuzz_targets/*.rs
cargo clippy --all-targets -- -D warnings
cargo test
../.forgejo/scripts/server-coverage.sh   # line, branch and region coverage of native-note-core/src, excluding tests.rs
```

The coverage script enforces the [coverage gate](server/DESIGN.md#server-core) and lists anything missed. Property tests live in modules named `props`, which the coverage run skips, and no other test's path contains `props`.

A new vector file, or a new case in a file the server replays, fails the suite until `native-note-core/tests/suite/support/vectors.rs` lists it as replayed or client-only.

Fuzzing is manual, not in CI, on the nightly pinned in the coverage script. Run each target overnight:

```sh
cargo install --locked cargo-fuzz@0.13.2
cd server/native-note-core
nightly="$(sed -n 's/^nightly="\(.*\)"$/\1/p' ../../.forgejo/scripts/server-coverage.sh)"
rustup toolchain install "$nightly" --profile minimal
cargo "+$nightly" fuzz run frame -- -max_total_time=28800 -malloc_limit_mb=16
cargo "+$nightly" fuzz run envelope -- -max_total_time=28800 -malloc_limit_mb=16
```

Minimize a finding with `cargo "+$nightly" fuzz tmin <target> <artifact>` and add its bytes as a regression test in `tests/suite`.

Supply chain, with cargo-deny and cargo-audit installed as above:

```sh
cd server
cargo deny --config ../deny.toml check
cargo audit --deny warnings
```

### macOS client

Open `clients/macos/native-note.xcodeproj` in Xcode 26.2 or newer on macOS 26.0. `xcodebuild` needs Xcode selected, not the Command Line Tools (`sudo xcode-select -s /Applications/Xcode.app`). The first build fetches SQLCipher and Argon2.

Touch ID unlock needs a team-signed build. Put your team in `clients/macos/Local.xcconfig`, which git ignores, and pass `-allowProvisioningUpdates` to `xcodebuild`:

```
DEVELOPMENT_TEAM = <your team ID>
NATIVE_NOTE_ENTITLEMENTS = NativeNote.entitlements
```

Without it the app builds without the keychain entitlement, Touch ID unlock is unavailable, and its keychain tests skip.

On a free Personal Team the development profile expires after 7 days; rebuild before then.

Build and install a Release copy:

```sh
cd clients/macos
xcodebuild build -project native-note.xcodeproj -scheme native-note -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build -allowProvisioningUpdates
rm -rf "/Applications/Native Note.app"
ditto "build/Build/Products/Release/Native Note.app" "/Applications/Native Note.app"
```

Package tests run without the app host:

```sh
cd clients/macos/native-note-kit
swift test
```

App and view tests run hosted:

```sh
cd clients/macos
xcodebuild test -project native-note.xcodeproj -scheme native-note -destination 'platform=macOS'
```

Read the `Test run with N tests` line, not `TEST SUCCEEDED`: `-only-testing` without the test's trailing `()` runs nothing and still succeeds.

Tests never present windows, sheets, or alerts. Call view logic directly or host the view in `OffscreenWindow`.

Every feature gets unit tests and headless end-to-end tests. End-to-end tests run real Argon2 and the Secure Enclave on the generated `RealisticCorpus` library and relaunch through a fresh `AppModel`, so the package run takes about two minutes. The force-quit test kills `NativeNoteTypist` while it types: everything typed before the 300 ms save window plus 100 ms must survive. The typing tests hold a keystroke on 1,000 notes to 20 times one in a plain text view and 3 times one on 10 notes, and a save to 100 ms at the 95th percentile.

Power loss is checked in a macOS VM: [devtools/macos-power-loss](devtools/macos-power-loss/README.md).

Coverage is off in the shared scheme. Measure the package with `swift test --enable-code-coverage`, and the hosted tests with the sandbox off, since a sandboxed host writes no coverage data:

```sh
rm -rf build/coverage.xcresult
xcodebuild test -project native-note.xcodeproj -scheme native-note -destination 'platform=macOS' -enableCodeCoverage YES -resultBundlePath build/coverage.xcresult ENABLE_APP_SANDBOX=NO
xcrun xccov view --report --only-targets build/coverage.xcresult
```

Views below `ContentView` take plain data, not `AppModel`, so the Xcode canvas can render them without a database. Sample fixtures live behind `#if DEBUG` — and so must the `#Preview` blocks that use them, because previews are compiled in Release too.

Package tests read `spec/vectors` from their bundle, copied in through the `Tests/NativeNoteKitTests/vectors` symlink. A new vector file fails the tests until `VectorFile` marks it replayed or deferred to a phase.

**Verified locally only.** CI has no macOS runner, so run both test commands before a pull request that touches the client.

## Rules

**A spec change is not done until the vectors are regenerated in the same commit.** CI fails if the generator produces a diff against what is committed.

**No floating dependencies.** No release candidates, no betas, no version ranges, no branch or tag references. Pin the strongest immutable reference the ecosystem offers: an exact version backed by a lockfile checksum, an exact commit revision, or a content hash.

**Adding a dependency to the server needs a written justification** in [server/DESIGN.md](server/DESIGN.md).

**Every claim in the README and docs must match the code.** A documentation claim the code does not support is treated as a defect.

## Naming

| Context                            | Form                                            | Examples                                                                          |
| ---------------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------- |
| Human-readable                     | `Native Note`                                   | window title, README, release notes                                               |
| Paths, URLs, identifiers           | `native-note`                                   | directories, repo, crates, Xcode targets                                          |
| PascalCase languages, mainly Swift | `NativeNote`                                    | type names, the files holding them, Swift modules (`NativeNote`, `NativeNoteKit`) |
| Where a hyphen is not allowed      | `nativenote` or `native_note`, decided per case | bundle IDs, Rust crate names in code                                              |

Never `nativeNote`. Never `NativeNote` outside a PascalCase language context — it is a type name, not a path.

The bundle ID is `dev.hloth.nativenote` rather than `dev.hloth.native-note` because Android package segments disallow hyphens and the identifier must be the same on every platform.

## Style

- Tabs for indentation, four-wide, where possible.
- Avoid comments, comment only what the code genuinely cannot say, and add a spec citation or reference link.
- Split files past roughly 300–400 lines into smaller modules.
- Aim for less code.
- Rust: `rustfmt` with hard tabs. Clippy warnings are errors.
- Swift: no `try!` outside tests. Database writes never run on `@MainActor`.
- Dates as `YYYY-MM-DD`. US English. Metric units.

## Security work

Read [docs/ARCHITECTURE.md § Threat model](docs/ARCHITECTURE.md#threat-model) before touching crypto, key storage, or the request path.

Never log secrets or plaintext. In the Rust server, key material stays in [`Secret<T>`](server/DESIGN.md#server-storage); the generator's published fixture keys stay bare. In Swift, key material stays in `SymmetricKey`, reaches no log or error, and its one text form is the raw-key literal buffer that `SQLiteConnection.withRawKeyLiteral` wipes after use.

Report vulnerabilities per [SECURITY.md](SECURITY.md) rather than in a public issue.
