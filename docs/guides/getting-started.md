# Native Note help

## Migrating to another machine

The encrypted notes library is bound to the device, so move notes through sync or an export. A device that synced before cannot join another library; its notes move through an export. Optionally secure the export with a passphrase to protect it during sending between machines.

## Changing the recovery phrase

In Settings, press Change Recovery Phrase…. This does not affect devices already enrolled in sync. The old words still open a server backup made before the change, and with it every note.

## Turning sync off or moving the library

To turn off sync, press Turn Off Sync… in Settings. This process does not affect notes on your device or on server. Set Up Sync… later finds the library again on its server, with no words to enter.

To move the library, press Change Server… in Settings: the same server at a new address keeps it, and an empty server takes it under a new recovery phrase. The old server keeps a copy nothing updates; its data directory can be deleted.

## Losing a device

[Replace the server's API key](setup-sync-server.md#connect-a-client), then enter it with Change Server… on each device that still syncs, keeping the address. The lost device can no longer sync, but its notes stay readable to whoever knows its unlock password.

## Losing everything

Only the recovery phrase with the server's key backup, a device holding the library and an export can read the notes.

## macOS

- Closing the window keeps Native Note running and the library unlocked; press ⌘L to lock it
- Changing fingerprint set disables Touch ID unlock

## Privacy

Read the [privacy policy](../PRIVACY.md).
