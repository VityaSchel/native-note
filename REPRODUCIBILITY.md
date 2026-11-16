# Native Note Reproducibility

Every release rebuilds byte for byte from its tag on the platforms named below, apart from the macOS app's signature, notarization ticket and provisioning profile. A rebuild trusts the code instead of whoever built the release. The server rebuilds in a few minutes; the macOS app in about 15.

Rebuilding needs the tag's checkout with its SQLCipher submodule: `git clone --recurse-submodules https://git.hloth.dev/hloth/native-note.git`, then `git checkout v<version>` and `git submodule update --init`.

- [Releases](#releases)
- [macOS app](#macos-app)
- [Sync server](#sync-server)

## Releases

Which platform reproduces each release:

| Release  | macOS zips                                         | Server tarballs                                  |
| -------- | -------------------------------------------------- | ------------------------------------------------ |
| `v0.1.0` | macOS on Apple silicon with Xcode 27A266a          | Linux on x86_64 (`x86_64-unknown-linux-gnu`)     |

## macOS app

- **Canonical builder:** macOS on Apple silicon with the Xcode build [macos-release.sh](.forgejo/scripts/macos-release.sh) pins, for both the `arm64` and `x86_64` zip.
- **Official releases:** built locally with `macos-release.sh`, signed with the Developer ID of team `L3W5ZXTBAF` and notarized.

Build hosts for both zips:

|          | On x86_64 | On arm64    |
| -------- | --------- | ----------- |
| On macOS | Untested  | _Canonical_ |

Pinned inputs:

| Component                                          | Where it's pinned                                                                                                      |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Xcode, with its Swift, clang, linker and macOS SDK | `xcode_build` in `macos-release.sh`                                                                                    |
| SQLCipher                                          | the `clients/macos/native-note-kit/sqlcipher` submodule, and the amalgamation's SHA-256 in `Scripts/sqlcipher-amalgamation.sh` |
| Argon2                                             | the project's `Package.resolved`, in `native-note.xcodeproj/project.xcworkspace/xcshareddata/swiftpm`                 |
| Version, build number and build settings           | `clients/macos/native-note.xcodeproj/project.pbxproj`                                                                  |

Apart from the signature, the stapled ticket and the provisioning profile, a zip depends only on the commit and the pinned Xcode:

- The commit is exported with `git archive` to `/private/tmp/native-note-release`, since Swift and the linker record absolute paths no flag removes; the SQLCipher amalgamation must match the commit's pinned hashes.
- `xcodebuild` and `zip` run under `env -i` with `TZ=UTC`, `LC_ALL=C`, `SOURCE_DATE_EPOCH` at the commit time and no Git config. `BuildMachineOSBuild` is the SDK's build. Swift packages come only from the project's `Package.resolved`.
- Each app is archived signed ad-hoc without a team. Files take the commit time and modes `755` and `644`; the zip holds sorted entries and no extra fields.
- Before signing, a zip holding the builder's home path, user, host or computer name, Git identity, hardware UUID or serial number is refused, outside the bundle identifier, the repository URL and the copyright line.
- Signing adds the team's application identifier, team identifier and keychain group to the archive's entitlements and embeds the team's Developer ID provisioning profile.

[macos-verify.sh](.forgejo/scripts/macos-verify.sh) rebuilds the checked-out commit and grafts each published app's signature, `_CodeSignature`, `CodeResources` and `embedded.provisionprofile` onto the rebuild. It requires the published entitlements to be the rebuild's plus exactly those three keys and the hardened runtime, then every file to match byte for byte and the published signature to verify. `actool` names the icon's fallback image after a random temporary file, so `Assets.car` is compared by its renditions. Who signed the app and its notarization are checked with `spctl`, not by the script.

```sh
# 1. Check out the release
git checkout v<version>
git submodule update --init

# 2. Fetch both zips into one directory from https://git.hloth.dev/hloth/native-note/releases
PUBLISHED=/path/to/published

# 3. Rebuild with the pinned Xcode in /Applications/Xcode.app, or set DEVELOPER_DIR
.forgejo/scripts/macos-verify.sh "$PUBLISHED"/Native-Note-<version>-arm64.zip "$PUBLISHED"/Native-Note-<version>-x86_64.zip
# -> ✓ Native-Note-<version>-arm64.zip is this build plus its own signature

# 4. Check the signer and the notarization
unzipped="$(mktemp -d)"
ditto -x -k "$PUBLISHED"/Native-Note-<version>-arm64.zip "$unzipped"
spctl -a -vv "$unzipped/Native Note.app"
# -> source=Notarized Developer ID
# -> origin=Developer ID Application: … (L3W5ZXTBAF)
```

## Sync server

- **Canonical builder:** Linux on x86_64 (`x86_64-unknown-linux-gnu`), for both the `x86_64` and `aarch64` tarball.
- **Official releases:** built by [release.yml](.forgejo/workflows/release.yml) on Debian 12 at two cloud providers, Vultr and Hetzner, once a release is published, and attached with their SHA-256 only when both builds match byte for byte.

Build hosts for both tarballs:

|            | On x86_64         | On arm64             |
| ---------- | ----------------- | -------------------- |
| On Linux   | _Canonical_       | NOT reproducible[^1] |
| On macOS   | Not buildable[^2] | NOT reproducible[^1] |
| On Windows | Untested[^3]      | NOT reproducible[^1] |

Pinned inputs:

| Component                           | Where it's pinned                                     |
| ----------------------------------- | ----------------------------------------------------- |
| Rust toolchain and the musl targets | `rust-toolchain.toml`                                 |
| Crates, bundled SQLite among them   | `server/Cargo.lock`                                   |
| `zig`, the C compiler               | `server-release.sh`, its version and SHA-256 per host |
| `rust-lld`, the linker              | the pinned Rust toolchain                             |

[server-release.sh](.forgejo/scripts/server-release.sh) builds a clean checkout into static musl binaries, remapping every local path and refusing a binary that still holds one, and packs each with [the systemd unit](server/native-note-server.service) into a tarball with fixed owner, modes, order and time, in `releases/`. GNU `tar` and `gzip` come from the host; the official builds use Debian 12's.

```sh
# 1. Check out the release
git checkout v<version>

# 2. Rebuild, with rustup, curl and xz installed
.forgejo/scripts/server-release.sh
# -> built on x86_64-unknown-linux-gnu

# 3. Fetch both tarballs and native-note-server-<version>.sha256 into one directory from https://git.hloth.dev/hloth/native-note/releases
PUBLISHED=/path/to/published

# 4. Confirm the published tarballs and the rebuild both match the published SHA-256
(cd "$PUBLISHED" && sha256sum -c native-note-server-<version>.sha256)
(cd releases && sha256sum -c "$PUBLISHED/native-note-server-<version>.sha256")
```

[^1]: Cargo hashes `rustc -vV`, which names the build host, into every crate, so only a build on `x86_64-unknown-linux-gnu` matches.

[^2]: `server-release.sh` pins `zig` only for Linux on x86_64 and arm64 and macOS on Apple silicon.

[^3]: Under WSL 2, which runs Linux on x86_64.
