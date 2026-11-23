# Native Note VoiceOver run

This development tool drives real VoiceOver through Native Note's common tasks and checks what VoiceOver says.

It runs on the Mac's own screen for a few minutes: VoiceOver speaks, the test copy of the app takes the front, and the pasteboard is borrowed for each text entry and restored.

```sh
cd devtools/macos-voiceover
swift test
runner="$(./build.sh)"
open -W "$runner" --args run
cat ~/Library/Developer/native-note-devtools/voiceover/report.txt
```

## Setup

Once per Mac:

- VoiceOver Utility > General: Allow VoiceOver to be controlled with AppleScript
- System Settings > Privacy & Security > Accessibility: Native Note VoiceOver Run, which the first run asks for

## Flow

`build.sh` builds, under `~/Library/Developer/native-note-devtools/voiceover/`:

- a copy of Native Note as `dev.hloth.devtools.native-note-voiceover`, ad-hoc signed with the app's sandbox, so its library lives in its own container and Touch ID is unavailable
- the sync server, which the run starts on `127.0.0.1:18457` with a fresh data folder
- the runner app `dev.hloth.devtools.native-note-voiceover-run`, signed with an Apple Development identity so the permissions above stay granted across rebuilds

A run starts from a fresh library, erasing a previous one through Forgot Password?, then walks onboarding, sync setup with the recovery words, a note, Sync Now, lock and unlock, Settings, export and erasing again.

## Checks

- VoiceOver reaches each control by moving its cursor and activates it with its own action
- VoiceOver says each step's title, field name, error and outcome, read from its last spoken phrase every 20 ms
- Keyboard and VoiceOver focus land where each step expects

Out of scope:

- Voice Control, which has no scripting interface
- Touch ID, which the test copy cannot use
- The open and save panels of import and export
