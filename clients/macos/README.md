# Native Note for macOS Architecture

Dependencies:

- CryptoKit
- Security
- [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) — revision `205df55` (`4.17.0`), a prebuilt XCFramework published by Zetetic
- [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) — revision `f57e61e`, built from source

## Implementation details

- Editor is `NSTextView` (TextKit 2) in an `NSViewRepresentable`, one text storage. We chose it over SwiftUI `TextEditor` because `TextEditor` cannot do reliable per-range styling, so the heading would need its own field and unified selection would break. Also the right base for the markdown editor later
- Database writes off `@MainActor`, published state on it, so it doesn't jank on large notes
- No `try!` outside tests, so it doesn't crash on any Keychain ACL or directory failure

Primitives:

- AES-256-GCM — `CryptoKit.AES.GCM`
- HKDF-SHA256 — `CryptoKit.HKDF<SHA256>`
- Argon2id — `phc-winner-argon2`, the reference implementation
- HMAC-SHA256 — `CryptoKit.HMAC<SHA256>`
- P-256 ECDH — `CryptoKit.SecureEnclave.P256.KeyAgreement`

SQLCipher uses the **CommonCrypto** backend, not a bundled OpenSSL — `PRAGMA cipher_provider` returns `commoncrypto` on a keyed connection.

Never set `PRAGMA temp_store`: `SQLITE_TEMP_STORE=2` makes memory the default, not a guarantee.

Local DB key's hardware binding uses Machine ID — the same passcode-to-hardware entanglement the SEP performs with its UID key for the device passcode, rebuilt from public APIs.

Optional biometric unlock stores Local DB key in the Keychain under `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`. `BiometryCurrentSet` is invalidated by the OS when the enrolled biometric set changes, so adding a fingerprint cannot silently extend access.

The unlock screen shows a "Unlock with Touch ID" button beside the password field's submit. Pressing it reads the Keychain item, which triggers the system biometric prompt.

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

`localSalt`, `argonParams` and `rounds` per [ARCHITECTURE.md](../DESIGN.md#unlock-parameters), stored in `app-lock.plist`, mode `0600`, the absolute path is `~/Library/Containers/dev.hloth.nativenote/Data/Library/Application Support/`.

```
version     1
localSalt   16 bytes
argon       { m: 262144, t: 3, p: 4 }    # m in KiB, so 262144 is 256 MiB
rounds      140
enclaveKey  Secure Enclave key blob      # absent without a Secure Enclave
```

A rekey writes `app-lock.next.plist` and keeps the old file until the new key is proven. Startup prefers the pending one.

### Machine ID

The Apple implementation of [`hardwareOp`](../DESIGN.md#hardwarechain). The Enclave can only hold **P-256** keys, so each round is a key agreement against it:

```
enclaveKey = SecureEnclave.P256.KeyAgreement.PrivateKey    # device-bound, non-extractable, no ACL flags

hardwareOp(x, i) {
    attempt = 0
    do {
        s = HKDF-SHA256(x, info: "native-note/machine-chain/v1/\(i)/\(attempt)", 32)
        attempt += 1
    } while (s is not a valid P-256 scalar)    # p ≈ 2⁻³² per draw
    return ECDH(enclaveKey, publicKey(s))      # runs on the chip
}
```

Rejection by redrawing from an incremented HKDF counter is the standard candidate-testing method from FIPS 186 key generation — deterministic and unbiased, unlike nudging bytes of a rejected value. Every input yields a valid scalar eventually, so the operation never fails on a wrong password. This loop must stay byte-identical across app versions, or the chain diverges and the database will not open.

`enclaveKey` is created with `kSecAccessControlPrivateKeyUsage`. Not `kSecAccessControlApplicationPassword`: a wrong password fails the unwrap immediately instead of requiring invoking the full chain.

