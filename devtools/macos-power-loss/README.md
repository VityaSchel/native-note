# Power-loss test harness, development only

Never part of Native Note and never shipped. Its macOS VM lives in `~/Library/Developer/native-note-devtools/power-loss/`, where `install` needs exactly one macOS restore image (`.ipsw`) and 30 GiB beyond the 40 GiB the harness keeps free; the VM's files stay under 45 GB. Inside the VM, setup installs the launch daemon `dev.hloth.devtools.native-note-power-loss-test`, which runs the agent and the typist from the kit folder the host shares, and turns off sleep and automatic updates. Setup runs only inside a virtual machine and erases only the 2 GiB "Apple Inc. VirtIO Block Media" disk.

Each run cuts power while the typist types into a library on a disk the harness serves over NBD, tearing the first change after the cut unless `--tear off`. The volume must then mount, `integrity_check` must pass, and every acknowledged character, and nothing untyped, must be on disk. A drive losing its volatile cache is out of scope. Every early-ack control run must lose acknowledged text and fail no other check. `--seed` repeats each run's cut time and tear, from run 1. The typist's tests, the [force-quit budget](../../clients/DESIGN.md#local-db) among them, need the SQLCipher amalgamation that `build.sh` generates.

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
