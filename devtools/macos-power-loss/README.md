# Native Note power-loss test

This development tool launches a macOS VM for power-loss check.

The VM is saved to `~/Library/Developer/native-note-devtools/power-loss/`. `install` needs exactly one macOS restore image (`.ipsw`) there and 70 GiB free: up to 30 GiB for the VM plus the 40 GiB the harness keeps free. `install`, `setup` and `run` stop below 40 GiB free or when the VM's files exceed 45 GB.

```sh
cd devtools/macos-power-loss
swift test
harness="$(./build.sh)"
swift test --package-path typist
"$harness" install
"$harness" setup
"$harness" run --count 20
"$harness" run --count 5 --control early-ack
```

## Setup

Setup runs only inside a VM, where it:

- installs the launch daemon `dev.hloth.devtools.native-note-power-loss-test`, which runs the agent and the typist from the kit folder the host shares
- turns off sleep and automatic updates
- erases only the 2 GiB "Apple Inc. VirtIO Block Media" disk

## Flow

1. The disk is served over NBD
2. Typist types into a library
3. The power is cut, tearing the first change after the cut unless `--tear off`

## Checks

- The volume must mount
- `integrity_check` must pass
- Every acknowledged character, and nothing untyped, must be on disk
- Every early-ack control run must lose acknowledged text and fail no other check

Out of scope:

- A drive losing its volatile cache

## Options

- `--seed` repeats each run's cut time and tear, from run 1

The typist's tests, the [force-quit budget](../../clients/DESIGN.md#local-db) among them, need the SQLCipher amalgamation that `build.sh` generates.
