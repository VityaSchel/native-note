# Native Note Roadmap

- **SAS device pairing** for secure Content key transfer to a new device. Ephemeral key exchange relayed by the server, authenticated by out-of-band comparison. Fingerprint verification must be select-from-decoys, never yes/no. Reintroduces a key exchange and therefore harvest-now-decrypt-later exposure on a key that never rotates. macOS 26+: `XWingMLKEM768X25519`, Android: no equivalent.
- **Notebooks, tags, pins, trash.**
- **Authenticated manifest against withholding.** A canonical list of `{blindedId, v}` for every live note, sealed under a content-key-derived key, with its own version counter.
