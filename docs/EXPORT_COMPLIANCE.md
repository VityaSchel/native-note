# Export compliance

Self-assessment of 2026-10-27, from the sources linked below; not legal advice. Recheck it before each release.

## Encryption in Native Note

Every algorithm is an industry standard; none is proprietary.

| Component    | Algorithms                                                     | Implementation              | Purpose                                                           |
| ------------ | -------------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------- |
| macOS app    | AES-256-GCM, HKDF-SHA256, HMAC-SHA256, P-256 ECDH              | CryptoKit                   | Note, transport and export encryption, blinding, hardware binding |
| macOS app    | AES-256-CBC with HMAC-SHA512 per page                          | SQLCipher, CommonCrypto     | Local database                                                    |
| macOS app    | Argon2id                                                       | phc-winner-argon2           | Unlock and export passwords                                       |
| macOS app    | TLS, when the server address is `https`                        | URLSession                  | Transport                                                         |
| Sync server  | AES-256-GCM, HKDF-SHA256, SHA-256                              | `ring`                      | Transport envelope                                                |

## App Store

- `ITSAppUsesNonExemptEncryption` is `YES` in [Info.plist](../clients/macos/Info.plist). SQLCipher's encryption goes beyond what the operating system provides ([Zetetic](https://discuss.zetetic.net/t/export-requirements-for-applications-using-sqlcipher/47)), so the app falls in [Apple's](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/) "industry standard algorithm, not provided within the Apple operating system" row: no US documentation in App Store Connect, and a French encryption declaration only for the French store.
- App Store Connect answers: uses encryption, yes; proprietary or non-standard algorithms, no; standard algorithms beyond the operating system's, yes.

## United States

- Mass-market encryption software, ECCN 5D992.c, under License Exception ENC, § 740.17(b)(1); no CCATS. The [2021 rule](https://www.thompsonhine.com/publications/bis-eliminates-most-mass-market-encryption-reporting-obligations) ended the annual self-classification report for mass-market software other than components.
- Open: [BIS's own page](https://www.bis.gov/learn-support/encryption-controls/encryption-items-not-subject-to-ear) still describes a one-time self-classification report for a free mass-market app and an email notification for publicly available encryption source code, which the 2021 rule summaries say ended. Confirm before the first release.

## France

- Distribution on the French App Store needs a declaration to ANSSI first, under decree 2007-663. Open: file it before the French store is enabled, or leave France out.

## App Transport Security

`NSAllowsArbitraryLoads` is `YES`, as [clients/DESIGN.md § Sync](../clients/DESIGN.md#sync) decides. Apple asks for a [justification at review](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads); submit:

> Native Note syncs only with a server its user hosts and enters by address, often a home-network name such as `nas.lan` served over plain HTTP, which no public certificate authority can certify, so neither the domains nor TLS can be known ahead. The app seals every request and response with AES-256-GCM under the user's own key before it leaves the Mac, so the transport does not depend on TLS, and it makes no other network connection.
