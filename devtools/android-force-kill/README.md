# Native Note Android force-kill check

Development only. This tool is not part of the app and installs nothing beyond the debug build and its test APK.

It runs `ForceKillTypist` from the Android instrumented tests: the typist sets up a scratch library in the debug app's files and types into one note every 25 ms, and the script kills the app at a random moment 2–5 s in with `am force-stop`. The verifier then opens the library and requires `integrity_check` to pass, the saved text to be a prefix of what was typed, and everything typed more than 400 ms before the last logged keystroke to be on disk ([clients/DESIGN.md § Local DB](../../clients/DESIGN.md#local-db)).

```sh
cd clients/android
./gradlew installDebug installDebugAndroidTest
ANDROID_SERIAL=<device> ../../devtools/android-force-kill/run.sh 12
```

Each round prints the verifier's line; a failing round prints its assertion and the script exits non-zero.
