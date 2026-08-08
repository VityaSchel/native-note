# Contributing

## Layout

```
docs/              cross-cutting design, sync protocol, roadmap
spec/vectors/      language-neutral conformance vectors
spec/generator/    Rust tool that generates and verifies them
server/            Cargo project, docs in its root
clients/           shared client design, one directory per platform
clients/macos/     Xcode project, docs in its root
```

## Build and test

### Server

```sh
cd server
cargo build --release
cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

Coverage:

```sh
cargo llvm-cov --package native-note-core --fail-under-lines 100 --fail-under-regions 100
cargo llvm-cov --package native-note-server --fail-under-lines 90
```

Supply chain:

```sh
cargo deny check
cargo audit
```

### macOS client

Open `clients/macos/native-note.xcodeproj` in Xcode 26.2 or newer. Requires macOS 26.0.

### Conformance vectors

```sh
cd spec/generator
cargo test                    # verify the generator reproduces every vector
cargo run --bin gen-vectors   # regenerate after an intentional protocol change
```

The generator is deterministic, salts, nonces, and keys are fixed. Regenerating without a protocol change must produce no diff.

## Rules

**A spec change is not done until the vectors are regenerated in the same commit.** CI fails if the generator produces a diff against what is committed.

**No pre-release dependencies.** No release candidates, no betas, no git dependencies. Pin exact versions.

**Adding a dependency to the server needs a written justification** in [server/ARCHITECTURE.md](server/DESIGN.md).

**Every claim in the README and docs must match the code.** A documentation claim the code does not support is treated as a defect.

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

Never log secrets or plaintext. The server wraps key material in a `Secret<T>` whose `Debug` prints `[redacted]`.

Report vulnerabilities per [SECURITY.md](SECURITY.md) rather than in a public issue.
