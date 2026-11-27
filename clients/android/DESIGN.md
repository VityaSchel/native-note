# Native Note Android architecture

Kotlin and Jetpack Compose in one Gradle module, `:app`. Android 12 (API 31) or later, targets API 36, compiles against API 37.1. Application ID `dev.hloth.nativenote`; debug builds add `.debug`, so tests never touch an installed release library.

Dependencies:

- Platform: `javax.crypto` through Conscrypt (AES-GCM, HMAC-SHA256, SHA-256), Android Keystore, `BiometricPrompt`, `HttpURLConnection`, `java.util.zip`
- Jetpack Compose through its BOM, Material 3, Material 3 adaptive, `activity-compose`, `lifecycle`
- [SQLCipher](https://github.com/sqlcipher/sqlcipher): `v4.17.0`, the revision macOS pins, built from source with the NDK, with FTS5 its only optional feature, on the LibTomCrypt backend
- [LibTomCrypt](https://github.com/sqlcipher/libtomcrypt): revision `476a957`, Zetetic's v1.18.2 with the CVE-2019-17362 fix, built from source with the NDK, as SQLCipher's crypto provider only
- [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2): revision `f57e61e`, built from source with the NDK

No Google Play services, Firebase, crash reporter, analytics, dependency-injection framework or navigation library.

## Implementation details

- AGP's built-in Kotlin, with the Compose compiler plugin at the Kotlin version. Versions are pinned inline in the build files, and every artifact is checked by `gradle/verification-metadata.xml`
- One `AppModel` held by the `Application`, with Compose snapshot state, mirroring macOS; no ViewModels
- `NavigableListDetailPaneScaffold`: two panes on wide windows, one on phones. Onboarding, locked and unlocked are model state, not navigation
- `MaterialExpressiveTheme` with `dynamicLightColorScheme` or `dynamicDarkColorScheme` and no colors of its own. On API 34+ these read the system's color roles, which One UI 9 leaves fixed while its palette follows the user; when the primary role's hue contradicts `system_accent1` and the contrast level is standard, the scheme is the one Compose builds from the palette on API 31–33
- The editor is `BasicTextField(TextFieldState)`; an `OutputTransformation` styles the first line as the title
- The search field is a plain `TextField`: `AppBarWithSearch` blocks the keyboard of the field inside it, since it expects a separate expanded search
- HKDF is written over `Mac("HmacSHA256")`
- The export zip writer and reader are our own, as on macOS: `ZipOutputStream` records MS-DOS as the creator, so `unzip` reads UTF-8 names in a DOS code page, and it refuses repeated names and adds a timestamp extra field after 2099. An import needing more than a quarter of the free heap is refused as too large for this device
- The export and import pickers keep the library unlocked while they are in front; turning the screen off locks it anyway, and a lock cancels the export the save picker was opened for
- Requests go through `HttpURLConnection` with the same fixed headers as macOS, no redirects, 30 s without data and 120 s in all. Cleartext is allowed; https trusts system and user CAs
- Sync's requests run off the library's worker thread, so a slow server never delays a save; a lock disconnects a request in flight and does not wait for its thread, which a name lookup or a connect can hold
- `IME_FLAG_NO_PERSONALIZED_LEARNING` on the password, API key and recovery-word fields only
- Recovery-word fields set `ContentDataType.None`, which keeps autofill services out; `importantForAutofill` on the Compose view does not. Passwords and the API key keep Compose's tags, so they can be filled, but typing in them cancels the autofill session, so no service offers to save them
- English only, every string in `strings.xml`; the libraries' translations are left out
- Share to Native Note (`ACTION_SEND`, `text/plain`) and a New Note launcher shortcut unlock first; shared text stays in memory only
- Password fields, the editor, the search field, the API key and the recovery words keep their text in `remember`, never in saveable state: a stopped activity's saved state goes to the system process. `configChanges` keeps the activity through every change Compose applies itself, so a rotation or a new font size loses none of it
- The pane scaffold's navigator moves its panes only when navigated, so the list screen re-applies its value when the window changes
- An edit carries the `v` of the note the editor shows, not of the row now in the list, so a key handled after a pull lands on a copy; a note left during a commit is flushed when the commit ends. A pulled text clears the editor's undo history, as on macOS, so undo never restores the text from before it
- An export refused or cut off deletes the document it left empty or partly written

## Accessibility

- An editable field's name is its `hintText`, and a visible placeholder is cleared from semantics: `contentDescription` on an editable field replaces its value. An error's text is set with `error()`; `isError` alone is spoken as "Invalid input"
- Each screen and step has a pane title that differs from its heading and from the screen before it, which is what makes TalkBack announce the change and move to the heading. The adaptive panes' own titles are replaced through their string resources
- With touch exploration on, a screen's first field takes focus only once the screen has been announced, and the Undo snackbar stays until it is dismissed or a note opens
- The pane scaffold focuses the pane it shows; in touch mode an empty focus target takes that focus, so neither the search field nor the editor opens the keyboard
- A busy button keeps its label in semantics with the state "In progress"; outcomes and errors are live regions, assertive where focus moves at the same time

## Platform equivalents

| clients/DESIGN.md                                | Android                                                                                                                  |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Lock on sleep, screen lock or session switch     | Lock when the activity stops: leaving the app, screen off and user switch. The app's own export and import picker is exempt |
| Sync when the app stops being active             | None: the lock cancels it, and edits push on the next unlock                                                             |
| Closing the window keeps the library unlocked    | Not applicable                                                                                                           |
| Quit with an unsaved edit asks first             | Not applicable: stopping saves at once, then locks                                                                       |
| `fullfsync`, `F_FULLFSYNC`                       | `synchronous=FULL`, re-applied after every open; `fsync` on the file and its directory                                   |
| Unlock record in the key store                   | A fixed-layout binary file in `noBackupFilesDir`                                                                        |
| Biometric prompt in the app's window             | The system `BiometricPrompt`, `BIOMETRIC_STRONG` only, no device credential                                              |
| Enrollment state hash                            | `KeyPermanentlyInvalidatedException` from `Cipher.init`                                                                  |
| Copy the recovery words, concealed and transient | Not offered: leaving the app to paste them would lock and cancel setup                                                   |
| Editor zoom                                      | The system font scale                                                                                                    |
| Menus and keyboard shortcuts                     | None                                                                                                                     |

The database, its sidecars, the unlock record and the biometric blob live in `noBackupFilesDir`. `allowBackup` is off and `dataExtractionRules` exclude everything.

`setRecentsScreenshotEnabled(false)` hides the Recents thumbnail on Android 13 and later. Android 12 and 12L keep the last screen there. There is no `FLAG_SECURE`.

### Unlock record

The [unlock record](../DESIGN.md#unlock-record) is the file `unlock-record` in `noBackupFilesDir`, mode `0600`, replaced through a temporary file, `fsync`, `rename` and an `fsync` of the directory:

```
version        1 byte = 0x01
localSalt      16 bytes
m, t, p        u32 big-endian each, m in KiB
hasMachineKey  1 byte, 0x00 or 0x01
machineKeyId   16 bytes, only when hasMachineKey
wrappedKey     60 bytes                       # localDbKey under unlockKey
```

Anything else is unreadable, never a first run.

### Machine ID

The Android [`hardwareOp`](../DESIGN.md#hardwarebinding):

```
machineKey   = Keystore HMAC-SHA256 key "native-note.machine.<hex machineKeyId>", StrongBox when present, else TEE
               no user authentication, no setUnlockedDeviceRequired; machineKeyId is random per setup
hardwareOp() = HMAC-SHA256(machineKey, "native-note/machine-id/v1")
```

A key whose `KeyInfo.securityLevel` is software is deleted, and `machineId` is left out with the warning. A missing key reads as notes bound to another device. Setup and erase delete every `native-note.machine.*` key first, since a library without a record leaves its key orphaned.

### Biometric unlock

```
biometricKey = Keystore AES-256-GCM key "native-note.biometric", BIOMETRIC_STRONG, valid 5 s after a touch,
               invalidated by enrollment changes, in StrongBox when the device has it
blob         = nonce ‖ AES-256-GCM(biometricKey, localDbKey, aad "native-note/biometric-key/v1")    # biometric-key
```

Turning it on takes one touch: encrypt `localDbKey`, store the blob, read it back and compare within the same 5 s. A canceled prompt during onboarding says so and stays; only Not now skips the offer. The prompt shows on its own when the unlock screen comes to the front, never right after a manual Lock, and again from a button after a cancel.

## Tests

- JVM unit tests for code that needs no device, with the vectors that need no native code
- Instrumented tests on a headless API 36 emulator: native code, Keystore, SQLCipher, end-to-end flows, and sync against the real server through `adb reverse`
- A hardware suite on a physical phone before each release, for StrongBox or TEE binding and the fingerprint
- Real TalkBack on an emulator, whose speech semantics assertions cannot predict: [devtools/android-talkback](../../devtools/android-talkback/README.md)
- Android Lint and Kotlin warnings are errors. Tabs, per `.editorconfig`; no formatter

## Release

- **Canonical builder:** Linux x86_64, Debian trixie with OpenJDK 21, at both CI providers; macOS arm64 reproduces
- Built from `git archive` under `env -i` and its own Gradle home, with JDK 21, platform 37.1 checked by its `android.jar` SHA-256, and NDK r30
- R8 with `-dontobfuscate`, no resource shrinking, `vcsInfo` and `dependenciesInfo` off; native code built with prefix maps, no build ID and no `.comment`
- The AAB leaves out R8's mapping and the native debug symbols, whose order depends on the build host
- ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`
- `versionName` is the shared release tag; `versionCode` is `major × 10000 + minor × 100 + patch`, written literally
- The APK on the Forgejo release and on F-Droid is signed with our own ECDSA P-384 key by `apksigner --alignment-preserved`. F-Droid publishes it from the main repository when its rebuild matches
- No published `apksigner` signs the Android 17 hybrid scheme (APK Signature Scheme v3.2, a classical key with ML-DSA) yet; when one does, the off-Play key rotates to a new P-384 key paired with ML-DSA-65, and the first key stays the signer for Android 16 and older
- Google Play gets the AAB under an RSA-4096 upload key, the only type Play accepts, and Play App Signing holds a Google-generated key, hybrid with ML-DSA-65 by default, so moving between Play and the other channels takes a reinstall
- `clients/android/release-certificate.sha256` pins the release key's certificate; signing with another key and verifying an APK under another key both fail
- F-Droid's recipe uses the subdir `clients/android`, one of the places F-Droid reads fastlane metadata from, runs `android-build.sh` and takes its unsigned APK; `UpdateCheckData` reads the versions from `app/build.gradle.kts`, and `Binaries` with `AllowedAPKSigningKeys` makes F-Droid publish our signed APK
- The package and the off-Play key are registered for Android developer verification
- The launcher icon is adaptive, generated from macOS's `AppIcon.icon`: the page is the background, so the launcher's mask is the page, and the rows and rings are the foreground and the monochrome layer
- Store metadata lives in `clients/android/fastlane` for F-Droid and Play. Play's Data safety form declares no data collected or shared, since notes leave the phone only end-to-end encrypted to a server the user runs; the privacy policy is [docs/PRIVACY.md](../../docs/PRIVACY.md)
- Settings → Third-Party Licenses shows `assets/licenses.txt`: SQLCipher's BSD notice, the SQLite and LibTomCrypt public-domain statements, Argon2's header (used under CC0) and the Apache-2.0 libraries with the license's full text. `LicensesTest` holds each text word for word to the pinned source and fails for a declared dependency group the file does not name
