# Contributing

## Layout

```
docs/              cross-cutting design, sync protocol, roadmap
spec/vectors/      language-neutral conformance vectors
spec/generator/    Rust tool that generates and verifies them
spec/wordlists/    BIP39 wordlists, pinned by hash
server/            Rust server, not written yet — docs in its root
clients/           shared client design, one directory per platform
clients/macos/     Xcode project, docs in its root
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
cargo test                    # verify the generator reproduces every vector
cargo run --bin gen-vectors   # regenerate after an intentional protocol change
```

The generator is deterministic, salts, nonces, and keys are fixed. Regenerating without a protocol change must produce no diff.

Supply chain:

```sh
cargo deny --config ../../deny.toml check
cargo audit
```

### Server

Not written yet — the design is in [server/DESIGN.md](server/DESIGN.md). It needs no workflow change
to gain CI: both workflows already run over `server/` as soon as a `server/Cargo.toml` exists.

### macOS client

Open `clients/macos/native-note.xcodeproj` in Xcode 26.2 or newer. Requires macOS 26.0. Swift Package Manager resolves SQLCipher and Argon2 on first open, so the first build needs network access.

```sh
cd clients/macos
xcodebuild test -project native-note.xcodeproj -scheme native-note -destination 'platform=macOS'
```

Both packages stay on the app target; tests reach them through the app module. A second consumer makes Xcode build Argon2 as a dynamic package framework, which then fails to link under coverage with an undefined `___llvm_profile_runtime`.

Coverage is off in the shared scheme — enabling it there instruments Release builds too. Per run:

```sh
xcodebuild test -enableCodeCoverage YES -project native-note.xcodeproj -scheme native-note -destination 'platform=macOS'
```

UI tests are skipped by default; they take over the login session. Run with `-only-testing:native-note-ui-tests`.

`spec/vectors` is a folder reference in the test target, not a path read at runtime.

**Verified locally only.** CI has no macOS runner, so a green CI run says nothing about the client —
run the Xcode tests before opening a pull request that touches it. Anyone reproducing a macOS build
is a macOS user by definition, so a macOS-only host costs no reach.

## Rules

**A spec change is not done until the vectors are regenerated in the same commit.** CI fails if the generator produces a diff against what is committed.

**No floating dependencies.** No release candidates, no betas, no version ranges, no branch or tag references. Pin the strongest immutable reference the ecosystem offers: an exact version backed by a lockfile checksum, an exact commit revision, or a content hash.

**Adding a dependency to the server needs a written justification** in [server/DESIGN.md](server/DESIGN.md).

**Every claim in the README and docs must match the code.** A documentation claim the code does not support is treated as a defect.

## Naming

| Context                                | Form                                              | Examples                                    |
| -------------------------------------- | ------------------------------------------------- | ------------------------------------------- |
| Human-readable                         | `Native Note`                                     | window title, README, release notes         |
| Paths, URLs, identifiers               | `native-note`                                     | directories, repo, crates, Xcode targets    |
| PascalCase languages, mainly Swift     | `NativeNote`                                      | type names and the files holding them       |
| Where a hyphen is not allowed          | `nativenote` or `native_note`, decided per case   | bundle IDs, Swift module names              |

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

Never log secrets or plaintext. Key material must be wrapped in a type whose `Debug` prints `[redacted]`, never held in a bare byte array.

Report vulnerabilities per [SECURITY.md](SECURITY.md) rather than in a public issue.
