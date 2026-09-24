# Native Note for macOS Architecture

Dependencies:

- CryptoKit
- Security
- [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) — revision `205df55` (`4.17.0`), a prebuilt XCFramework published by Zetetic
- [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) — revision `f57e61e`, built from source

## Implementation details

- Crypto, storage, unlock and the model live in the local package `NativeNoteKit`, so they test without the app host
- Editor is `NSTextView` (TextKit 2) in an `NSViewRepresentable`, one text storage. We chose it over SwiftUI `TextEditor` because `TextEditor` cannot do reliable per-range styling, so the heading would need its own field and unified selection would break. Also the right base for the markdown editor later
- Database writes off `@MainActor`, published state on it, so it doesn't jank on large notes
- Argon2 and Secure Enclave calls run on `Unlock`'s serial queue, off the main actor and the concurrency pool, which concurrent Secure Enclave calls deadlock
- Lock closes the store once its saves land; a failing save keeps it open until the save lands or the next unlock
- `AppModel` is owned by the `AppDelegate`, not the `App`, so `applicationShouldTerminate` can hold quit until pending saves land
- No `try!` outside tests, so it doesn't crash on any Keychain ACL or directory failure
- The test host runs with `.prohibited` activation, so tests never take focus or show in the Dock

Primitives:

- AES-256-GCM — `CryptoKit.AES.GCM`
- HKDF-SHA256 — `CryptoKit.HKDF<SHA256>`
- Argon2id — `phc-winner-argon2`, the reference implementation
- HMAC-SHA256 — `CryptoKit.HMAC<SHA256>`
- P-256 ECDH — `CryptoKit.SecureEnclave.P256.KeyAgreement`

SQLCipher uses the **CommonCrypto** backend, not a bundled OpenSSL — `PRAGMA cipher_provider` returns `commoncrypto` on a keyed connection.

Never set `PRAGMA temp_store`: `SQLITE_TEMP_STORE=2` makes memory the default, not a guarantee.

Biometric unlock (planned) keeps `localDbKey` in the Keychain under `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, per [clients/DESIGN.md](../DESIGN.md#unlocking-with-biometrics), so a new fingerprint cannot unlock it.

### Entitlements

| Entitlement                                         | Reason     |
| --------------------------------------------------- | ---------- |
| `com.apple.security.app-sandbox`                    | on         |
| `com.apple.security.network.client`                 | sync       |
| `com.apple.security.files.user-selected.read-write` | zip export |

`com.apple.security.get-task-allow` is injected for non-distribution signing and lets any local process attach a debugger to the running app, which holds the content key in memory. Release builds must be signed for distribution so that it is dropped.

### Storage

| State             | Store                  |
| ----------------- | ---------------------- |
| App preferences   | `UserDefaults`         |
| Unlock parameters | `app-lock.plist`       |
| Notes             | the SQLCipher database |

Unlock parameters are stored in a binary plist because they're part of the database's identity, migrated along with it and not overridable by a managed value from a configuration profile.

### Unlock parameters

`localSalt` and `argonParams` per [clients/DESIGN.md](../DESIGN.md#unlock-parameters), stored in `app-lock.plist`, mode `0600`, the absolute path is `~/Library/Containers/dev.hloth.nativenote/Data/Library/Application Support/`.

```
version     1
localSalt   16 bytes
argon       { m: 262144, t: 3, p: 4 }    # m in KiB, so 262144 is 256 MiB
enclaveKey  Secure Enclave key blob      # absent without a Secure Enclave
```

A rekey writes `app-lock.next.plist` and keeps `app-lock.plist` until the new key is proven. Startup tries the pending file first and falls back to the current one, so an interrupted rekey still opens.

### Machine ID

The Apple implementation of [`hardwareOp`](../DESIGN.md#hardwarebinding). The Enclave holds only **P-256** keys, so the operation is a key agreement of the device key with its own public key:

```
enclaveKey = SecureEnclave.P256.KeyAgreement.PrivateKey    # device-bound, non-extractable, no ACL flags
hardwareOp() = ECDH(enclaveKey, publicKey(enclaveKey))     # d²G, runs on the chip
```

`app-lock.plist` stores the key blob, and that blob contains `dG` in the clear. Recovering `d²G` from `dG` is the computational Diffie-Hellman problem, so the result is unreachable without the chip. `enclaveKey` is created with `kSecAccessControlPrivateKeyUsage`.

