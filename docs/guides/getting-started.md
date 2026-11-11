# Getting started

There is no release yet. Build and install the Mac app per [CONTRIBUTING.md](../../CONTRIBUTING.md#macos-client); it runs on macOS 26.

1. On first launch, choose Next, then set an unlock password. It encrypts the notes on this Mac and cannot be recovered: a forgotten password means erasing the library, and only a synced library or an export comes back.
2. On a Mac with Touch ID, Native Note offers to unlock with it. Set Up Touch ID asks for one touch; Skip leaves it to Settings.
3. Native Note then offers to set up sync. Run a [sync server](setup-sync-server.md), choose Set Up and enter its address and API key, or choose Not Now: notes work without a server, and Settings has Set Up Sync… for later.
4. Write down the 24 recovery words Native Note shows, then type back the three it asks for. Native Note never keeps them; with them and the API key, the notes can be restored.

## Another Mac, or a wiped one

Set an unlock password, then, when Native Note offers to set up sync, choose Set Up and enter the same address and API key. The server already holds a library, so Native Note asks for its current 24 words, then syncs every note. A Mac that already has notes joins from Settings → Set Up Sync…, and its notes sync too.

## Changing the recovery phrase

In Settings, choose Change Recovery Phrase…. The old words no longer open the server's library, but a server backup made before the change still opens with them, and the key inside reads every note. Macs that already sync keep syncing.

## Turning sync off or moving the library

In Settings, Turn Off Sync… stops syncing and keeps every note on the Mac. Set Up Sync… later finds the library again on its server, with no words to enter. Change Server… points a syncing Mac at the server's new address, or moves the library to an empty server under new recovery words; the old server then holds a copy that nothing updates, and its data directory can be deleted.

## Losing a Mac

[Replace the server's API key](setup-sync-server.md#connect-a-client), then on each Mac that still syncs, choose Change API Key… in Settings and enter the new key. The lost Mac can no longer sync, but its notes stay readable to whoever knows its unlock password.

## Losing everything

Losing the recovery phrase, every Mac that holds the library and every export loses the notes for good. Neither the server nor its backups can recover them.
