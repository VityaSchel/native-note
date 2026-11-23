# Building Native Note

Check out the release tag with its submodules:

```sh
git clone --recurse-submodules --branch v0.1.1 https://git.hloth.dev/hloth/native-note.git
cd native-note
```

## Releases

Platforms that reproduced each release:

| Release  | Sync server               | macOS app   | Android app               |
| -------- | ------------------------- | ----------- | ------------------------- |
| `v0.1.1` | Linux x86_64, macOS arm64 | macOS arm64 | Linux x86_64, macOS arm64 |
| `v0.1.0` | Linux x86_64, macOS arm64 | macOS arm64 | —                         |

## Sync server

- **Canonical builder:** Linux x86_64
- **Official releases:** built by [release.yml](.forgejo/workflows/release.yml) at two cloud providers and offered for download only when both builds match, then rebuilt on macOS arm64 by [release-sign.sh](.forgejo/scripts/release-sign.sh), which signs every file's SHA-256 in the release notes with the maintainer's GPG key only when every binary, zip and APK matches; the maintainer publishes the release by hand

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

# 2. Fetch the published binaries and the SHA-256 sums signed in the release notes, with gpg and jq installed
curl -fsSLO "https://git.hloth.dev/hloth/native-note/releases/download/v0.1.1/native-note-server-linux-{x86_64,aarch64,armv7l,armv6l}"
curl -fsSL https://git.hloth.dev/api/v1/repos/hloth/native-note/releases/tags/v0.1.1 | jq -r .body | tr -d '\r' | sed -n '/^-----BEGIN PGP SIGNED MESSAGE-----$/,/^-----END PGP SIGNATURE-----$/p' > SHA256SUMS.asc

# 3. Compare
gpg --verify SHA256SUMS.asc && gpg --output - --decrypt SHA256SUMS.asc 2>/dev/null | grep -E '^[0-9a-f]{64}  ' > SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
(cd releases && sha256sum -c --ignore-missing ../SHA256SUMS)
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
curl -fsSLO "https://git.hloth.dev/hloth/native-note/releases/download/v0.1.1/native-note-v0.1.1-macos-{arm64,x86_64}.zip"

# 3. Compare
.forgejo/scripts/macos-verify.sh native-note-v0.1.1-macos-arm64.zip native-note-v0.1.1-macos-x86_64.zip
```

## Android app

- **Canonical builder:** Linux x86_64, Debian trixie with OpenJDK 21
- **Official releases:** built by [release.yml](.forgejo/workflows/release.yml) at two cloud providers and offered for download only when both builds match, then rebuilt on macOS arm64 by [release-sign.sh](.forgejo/scripts/release-sign.sh), which signs the APK with the release key through [android-sign.sh](.forgejo/scripts/android-sign.sh); F-Droid rebuilds each release and publishes that signed APK only when its own build matches
- **Not reproducible:** the signature. Google Play installs APKs that Google cuts from the AAB and signs with its own key, so only the APK on the release page and on F-Droid can be checked

|         | x86_64      | arm64        |
| ------- | ----------- | ------------ |
| Linux   | _Canonical_ | Untested     |
| macOS   | Untested    | Reproducible |
| Windows | Untested    | Untested     |

| Component                                                    | Where it's pinned                                                                              |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| JDK major version                                            | `java_major` in `android-build.sh`                                                             |
| Gradle                                                       | `clients/android/gradle/wrapper/gradle-wrapper.properties`, with its SHA-256                   |
| AGP, Kotlin, Compose and every other artifact Gradle fetches | the build files, each artifact's SHA-256 in `clients/android/gradle/verification-metadata.xml` |
| SDK platform, build-tools, NDK and CMake                     | `install-android-sdk.sh`; the platform's `android.jar` by SHA-256 in `android-build.sh`        |
| Argon2 and LibTomCrypt                                       | `clients/android/argon2`, `clients/android/libtomcrypt`                                        |
| SQLCipher                                                    | `clients/macos/native-note-kit/sqlcipher`, `Scripts/sqlcipher-amalgamation.sh`                 |
| Version and version code                                     | `clients/android/app/build.gradle.kts`                                                         |
| Release certificate                                          | `clients/android/release-certificate.sha256`                                                   |

[android-build.sh](.forgejo/scripts/android-build.sh) exports the commit with `git archive` to a fixed path and builds under `env -i`, with its own Gradle home, strict dependency verification and the commit's time. [android-verify.sh](.forgejo/scripts/android-verify.sh) grafts the published APK's signature onto that build and requires the result to match the published APK byte for byte, with a valid signature by the pinned release certificate.

```sh
# 1. Build into /tmp/native-note-android/out, with JDK 21 in JAVA_HOME and the pinned SDK in ANDROID_HOME (install-android-sdk.sh installs it on Debian or Ubuntu)
.forgejo/scripts/android-build.sh

# 2. Fetch the published APK
curl -fsSLO "https://git.hloth.dev/hloth/native-note/releases/download/v0.1.1/native-note-v0.1.1-android.apk"

# 3. Compare
.forgejo/scripts/android-verify.sh native-note-v0.1.1-android.apk
```

[^1]: `server-cross.sh` pins `zig` for Linux x86_64 and arm64 and for macOS arm64 only.

[^2]: Under WSL 2, which runs Linux.
