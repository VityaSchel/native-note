# Native Note

A personal note-taking app for macOS, self-hosted and end-to-end encrypted. Android, iOS, Windows and Linux come later. The optional sync server is a single Rust binary.

> [!NOTE]
> Work in progress. The macOS app and the sync server work; releases and the external code audit are *planned*.

## Features

- 🍃 **Native:** a SwiftUI app for macOS
- 📏 **Straightforward:** feels like Apple's Notes app — no learning curve and no overengineering
- 🪨 **Rock-solid:** prioritizes security and reliability
- 🔐 **Secure:** notes stay encrypted under a key bound to the Secure Enclave where the Mac has one, with optional Touch ID unlock; a human code audit is *planned* before the first release
- 🪶 **Lightweight:** the optional sync server is a single Rust executable binary (🚀🚀🚀)
- ☁️ **Syncable:** self-host a sync & backup server to use the app across several devices, with every note end-to-end encrypted

100% free, no ads, no data collection, no telemetry, ever.

## Download

No release yet. Build the macOS app from source and set it up per [Getting started](docs/guides/getting-started.md); to sync, run a [sync server](docs/guides/setup-sync-server.md).

<!-- Get started by downloading the app for your platform: -->

<!-- - Windows: [exe](https://git.hloth.dev/hloth/native-note/releases) -->
<!-- - Linux: [deb](https://git.hloth.dev/hloth/native-note/releases) / [rpm](https://git.hloth.dev/hloth/native-note/releases) / [AppImage](https://git.hloth.dev/hloth/native-note/releases) -->
<!-- - macOS: [App Store](https://apps.apple.com/) / [dmg](https://git.hloth.dev/hloth/native-note/releases) -->
<!-- - Android: [Play Store](https://play.google.com/store/apps/details?id=dev.hloth.nativenote) / [apk](https://git.hloth.dev/hloth/native-note/releases) -->
<!-- - iOS: [App Store](https://apps.apple.com/) / [AltStore]() -->

<!-- Then, optionally self-host a sync & backup server to share notes across multiple devices:

- [Getting started with server](./docs/guides/setup-sync-server.md) -->

## License

[MIT](./LICENSE)
