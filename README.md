# Native Note

A FLOSS personal native note-taking app for Windows, Linux, macOS, Android and iOS. Self-hosted and end-to-end encrypted.

<picture>
	<source media="(prefers-color-scheme: dark)" srcset="https://git.hloth.dev/hloth/native-note/raw/branch/main/docs/screenshots/devices-dark.avif">
	<img alt="Native Note on a laptop" src="https://git.hloth.dev/hloth/native-note/raw/branch/main/docs/screenshots/devices-light.avif" width="1012">
</picture>

## Features

- 🍃 **Native:** a notarized SwiftUI app for macOS and a Jetpack Compose app for Android
- 📏 **Straightforward:** no overengineering or learning curve
- 🪨 **Solid:** prioritizes security and reliability
- 🔐 **Secure:** notes encrypted with a <abbr title="macOS: only when Secure Enclave is available; Android: only with StrongBox or a TEE">hardware-bound</abbr> key, biometrics unlock
- 🛡️ **Safe:** reproducible releases, supply-chain checks, human code audit
- ☁️ **Multi-device:** set up sync via self-hosted server with E2EE
- 🪶 **Lightweight:** the sync server is a single 🚀Rust🚀 binary

100% free. No ads. No data collection. No telemetry or analytics. All releases are [reproducible](./BUILD.md).

## Download

1. Download Native Note:

- Windows: *WIP* <!-- [exe](https://git.hloth.dev/hloth/native-note/releases) -->
- Linux: *WIP* <!-- [deb](https://git.hloth.dev/hloth/native-note/releases) / [rpm](https://git.hloth.dev/hloth/native-note/releases) / [AppImage](https://git.hloth.dev/hloth/native-note/releases) -->
- macOS: <!-- [App Store](https://apps.apple.com/) / -->[zip for Apple silicon](https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-v0.1.0-macos-arm64.zip) / [zip for Intel](https://git.hloth.dev/hloth/native-note/releases/download/v0.1.0/native-note-v0.1.0-macos-x86_64.zip)
- Android: *WIP* <!-- [Google Play](https://play.google.com/store/apps/details?id=dev.hloth.nativenote) / [F-Droid](https://f-droid.org/packages/dev.hloth.nativenote/) / [apk](https://git.hloth.dev/hloth/native-note/releases) -->
- iOS: *WIP* <!-- [App Store](https://apps.apple.com/) / [AltStore]() -->

2. Optionally, self-host the sync server to automatically sync notes across your devices:

- [Getting started with server](./docs/guides/setup-sync-server.md)

## License

[MIT](./LICENSE)
