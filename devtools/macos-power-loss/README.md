# Power-loss test harness, development only

Never part of Native Note and never shipped. Its macOS VM lives in `~/Library/Developer/native-note-devtools/power-loss/`, where `install` needs the macOS restore image (`.ipsw`). Inside the VM, setup installs the launch daemon `dev.hloth.devtools.native-note-power-loss-test` and the typist, and turns off sleep and automatic updates.

Each run cuts power while the typist types into a library on a disk the harness serves over NBD, tearing the first change after the cut. The volume must then mount, `integrity_check` must pass, and every acknowledged character, and nothing untyped, must be on disk. A drive losing its volatile cache is out of scope. Every early-ack control run must lose acknowledged text. `--seed` replays a run.

```sh
cd devtools/macos-power-loss
swift test
harness="$(./build.sh)"
"$harness" install
"$harness" setup
"$harness" run --count 20
"$harness" run --count 5 --control early-ack
```
