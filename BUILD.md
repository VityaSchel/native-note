# Building Native Note

Check out the release tag with its SQLCipher submodule:

```sh
git clone --recurse-submodules --branch v0.1.0 https://git.hloth.dev/hloth/native-note.git
cd native-note
```

## Releases

Platforms that reproduced each release:

| Release  | Sync server  | macOS app   |
| -------- | ------------ | ----------- |
| `v0.1.0` | Linux x86_64 | macOS arm64 |

## Sync server

- **Canonical builder:** Linux x86_64
- **Official releases:** built by [release.yml](.forgejo/workflows/release.yml) at two cloud providers and published only when both builds match, then rebuilt on macOS arm64 by [server-sign.sh](.forgejo/scripts/server-sign.sh), which signs `SHA256SUMS` with the maintainer's GPG key only when every binary matches

|         | x86_64            | arm64        |
| ------- | ----------------- | ------------ |
| Linux   | _Canonical_       | Reproducible |
| macOS   | Not buildable[^1] | Reproducible |
| Windows | Untested[^2]      | Untested[^2] |

| Component                               | Where it's pinned                        |
| --------------------------------------- | ---------------------------------------- |
| Rust toolchain and the musl targets     | `rust-toolchain.toml`                    |
| Crates, bundled SQLite among them       | `server/Cargo.lock`                      |
| `zig`, the C compiler, and each ARM CPU | `server-cross.sh`, with SHA-256 per host |
| `rust-lld`, the linker                  | the pinned Rust toolchain                |

[server-release.sh](.forgejo/scripts/server-release.sh) builds one static musl binary per target with local paths remapped and refuses one that still holds a local path or code for another ARM CPU. [rustc-metadata.sh](.forgejo/scripts/rustc-metadata.sh) gives each crate a hash that does not depend on the build host, and the `.comment` section, where each host's linker names its own build, is removed.

```sh
# 1. Build into releases/, with rustup, cc, curl and xz installed
.forgejo/scripts/server-release.sh

# 2. Fetch the published binaries and their signed SHA-256 sums
curl -fsSLO "https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/{native-note-server-linux-x86_64,native-note-server-linux-aarch64,native-note-server-linux-armv7l,native-note-server-linux-armv6l,SHA256SUMS,SHA256SUMS.asc}"

# 3. Compare
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
(cd releases && sha256sum -c ../SHA256SUMS)
```

## macOS app

- **Canonical builder:** macOS arm64
- **Official releases:** built locally by [macos-release.sh](.forgejo/scripts/macos-release.sh), signed with the Developer ID of team `L3W5ZXTBAF` and notarized
- **Not reproducible:** the signature, notarization ticket and provisioning profile

|       | x86_64   | arm64       |
| ----- | -------- | ----------- |
| macOS | Untested | _Canonical_ |

| Component                                          | Where it's pinned                                                                    |
| -------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Xcode, with its Swift, clang, linker and macOS SDK | `xcode_build` in `macos-build.sh`                                                    |
| SQLCipher                                          | `clients/macos/native-note-kit/sqlcipher`, `Scripts/sqlcipher-amalgamation.sh`       |
| Argon2                                             | `Package.resolved`, `native-note.xcodeproj/project.xcworkspace/xcshareddata/swiftpm` |
| Version, build number and build settings           | `clients/macos/native-note.xcodeproj/project.pbxproj`                                |

[macos-build.sh](.forgejo/scripts/macos-build.sh) exports the commit with `git archive` to a fixed path and builds each architecture under `env -i` at the commit's time, signed ad-hoc. [macos-verify.sh](.forgejo/scripts/macos-verify.sh) grafts each published app's signature onto that build and requires every file to match byte for byte (`Assets.car` by its renditions), the build's entitlements plus the team's, the hardened runtime and Apple's notarization for team `L3W5ZXTBAF`.

```sh
# 1. Build into /private/tmp/native-note-release/out, with the pinned Xcode in /Applications/Xcode.app or DEVELOPER_DIR
.forgejo/scripts/macos-build.sh

# 2. Fetch the published zips
curl -fsSLO "https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-v0.1.0-{arm64,x86_64}.zip"

# 3. Compare
.forgejo/scripts/macos-verify.sh native-note-v0.1.0-arm64.zip native-note-v0.1.0-x86_64.zip
```

[^1]: `server-cross.sh` pins `zig` for Linux x86_64 and arm64 and for macOS arm64 only.

[^2]: Under WSL 2, which runs Linux.
