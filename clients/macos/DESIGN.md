# Native Note macOS architecture

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

Touch ID unlock keeps `localDbKey` in the data-protection keychain under `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, one item per library folder, per [clients/DESIGN.md](../DESIGN.md#unlocking-with-biometrics). Reading even that item's attributes needs a touch, so the enrollment's `LAContext.domainState.biometry.stateHash` sits in a second item, `dev.hloth.nativenote.unlock.enrollment`, with no access control; it is compared on every return to the app while `canEvaluatePolicy` succeeds.

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

[macos-build.sh](../../.forgejo/scripts/macos-build.sh) builds one zip per architecture, [macos-release.sh](../../.forgejo/scripts/macos-release.sh) signs and notarizes them, and [macos-verify.sh](../../.forgejo/scripts/macos-verify.sh) checks a published one against the build: [BUILD.md](../../BUILD.md#macos-app). [macos-appstore.sh](../../.forgejo/scripts/macos-appstore.sh) merges the same two builds with `lipo` into one universal app, since the App Store takes one upload per version, and signs it for the App Store into a `.pkg`. The shared Info.plist, not the App Store build alone, carries `ITSAppUsesNonExemptEncryption` and the `ITSEncryptionExportComplianceCode` App Store Connect issues once it approves the export documentation, the French encryption declaration among it, so the zips and the App Store build keep identical Info.plists; App Store Connect refuses an upload that sets the first without the second.

[PrivacyInfo.xcprivacy](native-note/PrivacyInfo.xcprivacy) declares no tracking and no collected data, and three required-reason APIs: `UserDefaults` for the editor zoom (`CA92.1`), and file timestamps (`C617.1`) and disk space (`E174.1`), which SQLite reads for files in the container, the reasons SQLCipher's own manifest gives.

### Unlock record

The [unlock record](../DESIGN.md#unlock-record) is a binary plist, kept in a data-protection keychain item of the signing team's group: service `dev.hloth.nativenote.library`, account `unlockRecord:` and the library folder's path, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronizable. Other code running as the user cannot read it, and it stays out of backups. A build without `keychain-access-groups` writes it to `app-lock.plist` beside the database instead, mode `0600`, in `~/Library/Containers/dev.hloth.nativenote/Data/Library/Application Support/`; a library made by a build of one kind, or signed by another team, does not open in the other.

```
version     1
localSalt   16 bytes
argon       { m, t, p }                  # m in KiB, per clients/DESIGN.md
enclaveKey  Secure Enclave key blob      # absent without a Secure Enclave
wrappedKey  60 bytes                     # localDbKey under unlockKey
```

### Machine ID

The Apple [`hardwareOp`](../DESIGN.md#hardwarebinding). The Enclave holds only **P-256** keys, so the operation is a key agreement of the device key with its own public key:

```
enclaveKey = SecureEnclave.P256.KeyAgreement.PrivateKey    # device-bound, non-extractable, no ACL flags
hardwareOp() = ECDH(enclaveKey, publicKey(enclaveKey))     # d²G, runs on the chip
```

`enclaveKey` is created with `kSecAccessControlPrivateKeyUsage`. The key blob in the unlock record holds `dG` in the clear; recovering `d²G` from it is the computational Diffie-Hellman problem.
