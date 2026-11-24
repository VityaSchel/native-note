# Native Note TalkBack run

This development tool drives real TalkBack through Native Note's common tasks on an emulator and checks what TalkBack says.

```sh
avdmanager create avd -n talkback -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_7
emulator -avd talkback -port 5596 -no-window -no-audio -no-snapshot -gpu swiftshader_indirect &
ANDROID_SERIAL=emulator-5596 devtools/android-talkback/run.sh
cat ~/Library/Developer/native-note-devtools/android-talkback/report.txt
```

Needs Bun, JDK 21 in `JAVA_HOME`, `ANDROID_HOME`, and a system image that includes TalkBack (`google_apis`). It refuses anything but an emulator: it turns TalkBack on, replaces the speech engine and clears `dev.hloth.nativenote.debug`, and puts the settings back when it ends.

- `speech/` is a text-to-speech engine, `dev.hloth.devtools.speech`, that logs every phrase it is asked to speak instead of speaking it; `CUT` marks one that was interrupted
- `talkback.ts` sends touches through the emulator console, which pass through TalkBack's touch exploration; `adb shell input swipe` does not. Typed keys switch touch mode off, which touch users never do, so a tap on the status bar puts it back
- `run.ts` is the walk: onboarding, a note, delete and Undo, search, Settings, Change Password, Export, sync setup against a local server, lock and unlock. Speech that comes late on a loaded machine is waited for
- Compose 1.13 reports a toggled switch with `CONTENT_CHANGE_TYPE_CHECKED`, which the image's TalkBack 15 does not speak, so the walk checks what the switch reads afterwards
