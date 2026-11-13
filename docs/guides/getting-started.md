# Getting started

There is no release yet. Build and install the Mac app per [CONTRIBUTING.md](../../CONTRIBUTING.md#macos-client); it runs on macOS 26.

1. Set an unlock password. It encrypts the notes on this Mac and cannot be recovered: a forgotten password means erasing the library, and only a synced library or an export comes back.
2. On a Mac with Touch ID, Set Up Touch ID asks for one touch; Skip leaves it to Settings.
3. To sync, run a [sync server](setup-sync-server.md), choose Set Up and enter its address and API key. Not Now leaves Set Up Sync… in Settings for later.
4. Choose Reveal, write down the 24 recovery words, then type back the three Native Note asks for. Native Note never keeps them; with them and the API key, the notes can be restored.

Lock with ⌘L. Closing the window keeps Native Note running and the library unlocked.

## Another Mac, or a wiped one

A library copied from another Mac does not open there: it is bound to that Mac's Secure Enclave. Notes move through sync or an export.

Set an unlock password, then choose Set Up and enter the same address and API key. Native Note asks for the current 24 words, then syncs every note. A Mac that already has notes joins from Settings → Set Up Sync…, and its notes sync too. A Mac that turned sync off keeps its own library and cannot join another one; its notes move through an export.

## Changing the recovery phrase

In Settings, choose Change Recovery Phrase…. Macs that already sync keep syncing. The old words no longer open the server's library, but they still open a server backup made before the change, and with it every note.

## Turning sync off or moving the library

Turn Off Sync… in Settings keeps every note on the Mac; Set Up Sync… later finds the library again on its server, with no words to enter. Change Server… points a syncing Mac at the server's new address, or moves the library to an empty server under new recovery words; the old server keeps a copy nothing updates, and its data directory can be deleted.

## Losing a Mac

[Replace the server's API key](setup-sync-server.md#connect-a-client), then on each Mac that still syncs choose Change Server… in Settings, keep the address and enter the new key. The lost Mac can no longer sync, but its notes stay readable to whoever knows its unlock password.

## Losing everything

Only the recovery phrase, a Mac holding the library and an export can read the notes. Losing all of them loses the notes for good; neither the server nor its backups can recover them.
