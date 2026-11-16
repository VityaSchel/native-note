# Native Note for macOS Architecture

Dependencies:

- CryptoKit
- LocalAuthentication
- LocalAuthenticationEmbeddedUI
- Security
- zlib — the system library, for the export zip's CRC-32
- [SQLCipher](https://github.com/sqlcipher/sqlcipher) — submodule at tag `v4.17.0`, built from source as an amalgamation, with FTS5 its only optional feature, with the CommonCrypto backend
- [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) — revision `f57e61e`, built from source

## Implementation details

- Crypto, storage, unlock and the model live in the local package `NativeNoteKit`, which tests without the app host
- The editor is `NSTextView` (TextKit 2) in an `NSViewRepresentable`, one text storage, not SwiftUI `TextEditor`, which cannot style per range
- The editor styles the title and writes the note from the text storage, so paste, undo and redo reach the note. Each note has its own undo history. Input-method text reaches the note on commit, and only text the editor did not show or write itself replaces its contents, so a composition survives a redraw
- Database writes run off `@MainActor`; published state lives on it
- Views below `ContentView` take plain data, not `AppModel`
- Argon2 and Secure Enclave calls run on one serial queue, `BlockingWork`, off the main actor and the concurrency pool; concurrent Secure Enclave calls deadlock
- The `AppDelegate` owns `AppModel`, so `applicationShouldTerminate` can hold quit until pending saves land
- Lock and quit clear what the editor's find bar put on the shared find pasteboard, unless something else was written since
- A build without `keychain-access-groups` never looks up the Touch ID key, and deletes it without an `LAContext`: each lookup holds one of the roughly 145 `LAContext` slots macOS shares between all processes until its context deallocates
- The test host runs with `.prohibited` activation, so tests never take focus or show in the Dock, and uses a private find pasteboard
- Never set `PRAGMA temp_store`: `SQLITE_TEMP_STORE=2` makes memory the default, not a guarantee

Touch ID unlock keeps `localDbKey` in the data-protection keychain under `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, one item per library folder, per [clients/DESIGN.md](../DESIGN.md#unlocking-with-biometrics).

The prompt is [`LAAuthenticationView`](https://developer.apple.com/documentation/localauthenticationembeddedui/laauthenticationview), created with a fresh `LAContext` per attempt and in the window before that context evaluates the key's access control. The key is read through the same context with interaction not allowed, then the context is invalidated, whatever the outcome. The view is never hidden, since the OS refuses a touch through a hidden view: it stays at full opacity behind the opaque password field.

### Entitlements

| Entitlement                                         | Reason                                   |
| --------------------------------------------------- | ---------------------------------------- |
| `com.apple.security.app-sandbox`                    | on                                       |
| `com.apple.security.network.client`                 | sync                                     |
| `com.apple.security.files.user-selected.read-write` | export and import                        |
| `keychain-access-groups`                            | Touch ID unlock, team-signed builds only |

App Transport Security allows arbitrary loads, for plain-`http` servers.

`com.apple.security.get-task-allow`, injected for non-distribution signing, lets any local process debug the app and read the content key from memory. Releases come only from [macos-release.sh](../../.forgejo/scripts/macos-release.sh), which refuses an app that keeps `get-task-allow`, lacks the hardened runtime or misses an entitlement.

### Release

Apart from the signature, the stapled ticket and the provisioning profile, a [release zip](../../.forgejo/scripts/macos-release.sh) depends only on the commit and Xcode 27A266a on an Apple silicon Mac:

- The commit is exported with `git archive` to `/private/tmp/native-note-release`, since Swift and the linker record absolute paths no flag removes; the SQLCipher amalgamation must match the commit's pinned hashes.
- `xcodebuild` and `zip` run under `env -i` with `TZ=UTC`, `LC_ALL=C`, `SOURCE_DATE_EPOCH` at the commit time and no Git config. `BuildMachineOSBuild` is the SDK's build. The version and build number are the project's.
- Each app is archived signed ad-hoc without a team. Files take the commit time and modes `755` and `644`; the zip holds sorted entries and no extra fields.
- Before signing, a zip holding the builder's home path, user, host or computer name, Git identity, hardware UUID or serial number is refused, outside the bundle identifier, the repository URL and the copyright line.
- Signing adds the team's application identifier, team identifier and keychain group to the archive's entitlements and embeds the team's Developer ID provisioning profile.

[macos-verify.sh](../../.forgejo/scripts/macos-verify.sh) grafts each published app's signature, `_CodeSignature`, `CodeResources` and `embedded.provisionprofile` onto the rebuild, requires the published entitlements to be the rebuild's plus exactly those three keys and the hardened runtime, then every file to match byte for byte and the published signature to verify. `actool` names the icon's fallback image after a random temporary file, so `Assets.car` is compared by its renditions. Who signed it and its notarization are checked with `spctl -a -vv`, not by the script.

### Unlock parameters

[Unlock parameters](../DESIGN.md#unlock-parameters) live in `app-lock.plist`, a binary plist beside the database, not `UserDefaults`, so they migrate with it and no configuration profile overrides them; mode `0600`, in `~/Library/Containers/dev.hloth.nativenote/Data/Library/Application Support/`. A password change writes the pending `app-lock.next.plist`.

```
version     1
localSalt   16 bytes
argon       { m, t, p }                  # m in KiB, per clients/DESIGN.md
enclaveKey  Secure Enclave key blob      # absent without a Secure Enclave
```

### Machine ID

The Apple [`hardwareOp`](../DESIGN.md#hardwarebinding). The Enclave holds only **P-256** keys, so the operation is a key agreement of the device key with its own public key:

```
enclaveKey = SecureEnclave.P256.KeyAgreement.PrivateKey    # device-bound, non-extractable, no ACL flags
hardwareOp() = ECDH(enclaveKey, publicKey(enclaveKey))     # d²G, runs on the chip
```

`enclaveKey` is created with `kSecAccessControlPrivateKeyUsage`. The key blob in `app-lock.plist` holds `dG` in the clear; recovering `d²G` from it is the computational Diffie-Hellman problem.
