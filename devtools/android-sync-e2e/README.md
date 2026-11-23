# Native Note Android sync end-to-end tests

Development only. This tool runs the Android client's sync tests against real servers on this computer and installs nothing beyond the debug build and its test APK.

It builds `server/`, starts one fresh server per test on ports from 18300, maps each into the device with `adb reverse`, and runs `ServerSyncTest`, `RecoveryServerTest`, `SyncSetupUiTest` and `ServerViewTest` with their addresses and API keys. The servers, their data and the port mappings are removed when it exits.

```sh
ANDROID_SERIAL=<device> devtools/android-sync-e2e/run.sh
```

Arguments after the script are passed to Gradle, such as `-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true` to keep the screenshots `SyncSetupUiTest` writes to the debug app's `files/renders`.

`cross-client.sh` checks convergence with the macOS client on one server: macOS's gated `CrossClientTests` sets up sync on a realistic library, Android's `CrossClientTest` joins it with the recovery phrase, checks it holds the same notes, edits, deletes and adds one, and macOS joins again and must see exactly that. Both compare a hash of the notes' UTF-8 bytes. It needs Xcode for `swift test`.
