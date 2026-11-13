# Native Note for macOS Architecture

Dependencies:

- CryptoKit
- LocalAuthentication
- LocalAuthenticationEmbeddedUI
- Security
- [SQLCipher](https://github.com/sqlcipher/sqlcipher) — submodule at tag `v4.17.0`, built from source as an amalgamation, with FTS5 its only optional feature
- [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) — revision `f57e61e`, built from source

## Implementation details

- Crypto, storage, unlock and the model live in the local package `NativeNoteKit`, which tests without the app host
- The editor is `NSTextView` (TextKit 2) in an `NSViewRepresentable`, one text storage, not SwiftUI `TextEditor`, which cannot style per range
- The editor styles the title and writes the note from the text storage, so paste, undo and redo reach the note. Each note has its own undo history. Input-method text reaches the note on commit, and only text the editor did not show or write itself replaces its contents, so a composition survives a redraw
- Database writes run off `@MainActor`; published state lives on it
- Argon2 and Secure Enclave calls run on one serial queue, `BlockingWork`, off the main actor and the concurrency pool; concurrent Secure Enclave calls deadlock
- Lock closes the store once its saves land; a failing save keeps it open until the save lands or the next unlock
- The `AppDelegate` owns `AppModel`, so `applicationShouldTerminate` can hold quit until pending saves land
- Lock and quit clear what the editor's find bar put on the shared find pasteboard, unless something else was written since
- The test host runs with `.prohibited` activation, so tests never take focus or show in the Dock, and uses a private find pasteboard
- Never set `PRAGMA temp_store`: `SQLITE_TEMP_STORE=2` makes memory the default, not a guarantee

Primitives:

- AES-256-GCM — `CryptoKit.AES.GCM`
- HKDF-SHA256 — `CryptoKit.HKDF<SHA256>`
- Argon2id — `phc-winner-argon2`, the reference implementation
- HMAC-SHA256 — `CryptoKit.HMAC<SHA256>`
- P-256 ECDH — `CryptoKit.SecureEnclave.P256.KeyAgreement`
- SQLCipher — the CommonCrypto backend, not a bundled OpenSSL

Touch ID unlock keeps `localDbKey` in the data-protection keychain under `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, one item per library folder, per [clients/DESIGN.md](../DESIGN.md#unlocking-with-biometrics).

### Entitlements

| Entitlement                                         | Reason                                   |
| --------------------------------------------------- | ---------------------------------------- |
| `com.apple.security.app-sandbox`                    | on                                       |
| `com.apple.security.network.client`                 | sync                                     |
| `com.apple.security.files.user-selected.read-write` | export and import                        |
| `keychain-access-groups`                            | Touch ID unlock, team-signed builds only |

The encryption declaration and the App Transport Security justification for review are in [docs/EXPORT_COMPLIANCE.md](../../docs/EXPORT_COMPLIANCE.md).

`com.apple.security.get-task-allow`, injected for non-distribution signing, lets any local process debug the app and read the content key from memory. Releases come only from [macos-release.sh](../../.forgejo/scripts/macos-release.sh): a clean checkout, exported with Developer ID, refused if it keeps `get-task-allow`, lacks the hardened runtime or misses an entitlement, and notarized as one app per architecture.

### Storage

| State                                                     | Store                           |
| --------------------------------------------------------- | ------------------------------- |
| Unlock parameters                                         | `app-lock.plist`                |
| Notes, and sync settings with the API key and Content key | the SQLCipher database (`meta`) |
| Touch ID copy of `localDbKey`                             | the data-protection keychain    |

Unlock parameters are a binary plist beside the database, not `UserDefaults`, so they migrate with it and no configuration profile can override them.

### Unlock parameters

[Unlock parameters](../DESIGN.md#unlock-parameters) live in `app-lock.plist`, mode `0600`, in `~/Library/Containers/dev.hloth.nativenote/Data/Library/Application Support/`. A password change writes the pending `app-lock.next.plist`.

```
version     1
localSalt   16 bytes
argon       { m: ≥262144, t: 3, p: 4 }   # m in KiB, calibrated per Mac from 256 MiB up to 2 GiB
enclaveKey  Secure Enclave key blob      # absent without a Secure Enclave
```

### Machine ID

The Apple [`hardwareOp`](../DESIGN.md#hardwarebinding). The Enclave holds only **P-256** keys, so the operation is a key agreement of the device key with its own public key:

```
enclaveKey = SecureEnclave.P256.KeyAgreement.PrivateKey    # device-bound, non-extractable, no ACL flags
hardwareOp() = ECDH(enclaveKey, publicKey(enclaveKey))     # d²G, runs on the chip
```

`enclaveKey` is created with `kSecAccessControlPrivateKeyUsage`. The key blob in `app-lock.plist` holds `dG` in the clear; recovering `d²G` from it is the computational Diffie-Hellman problem.
