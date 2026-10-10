# Power-loss test harness, development only

Never part of Native Note and never shipped. On the host it installs nothing besides its data folder, `~/Library/Developer/native-note-devtools/power-loss/`. Inside its own macOS VM it installs the launch daemon `dev.hloth.devtools.native-note-power-loss-test` with its launcher in `/usr/local/libexec/native-note-power-loss/`, the sudoers rule `/etc/sudoers.d/native-note-power-loss`, its SSH key in the VM account's `~/.ssh/authorized_keys` and the typist in `/Users/Shared/NativeNotePowerLoss/`, turns on Remote Login, and turns off sleep and automatic updates.

The harness runs the VM on Apple's Virtualization framework, with the library on a disk it serves over NBD. On macOS 27 that attachment forwards none of the guest's flushes or barriers, so the disk is an ordered prefix: acknowledged writes are durable, the first change after a cut is torn at a seeded 4 KiB boundary, and the rest is dropped. It catches saves acknowledged before they are durable, broken ordering and failed recovery, not an SSD losing its volatile cache, and it assumes Virtualization keeps the guest's write order.

After each cut the volume must mount, `integrity_check` must pass, and every acknowledged character, and nothing untyped, must be on disk. Cuts alternate between 0.2–6 s and 20–60 s into typing, and `run` counts those that land after a WAL checkpoint. Every early-ack control run must lose acknowledged text. The VM lives in the data folder, where `install` needs the macOS restore image (`.ipsw`).

```sh
cd devtools/macos-power-loss
swift test
harness="$(./build.sh)"
"$harness" install
"$harness" setup
"$harness" run --count 20
"$harness" run --count 5 --control early-ack
```

`--seed` replays a run. `diagnose` shows what the NBD server receives for `fsync` and `F_FULLFSYNC`, to recheck once Virtualization forwards flushes.

## Shell in the VM

Get a shell with `"$harness" setup`: it opens the VM window, where you log in and open Terminal. The kit is at `/Volumes/My Shared Files/kit/`. Finish every `setup` session with `sudo sh "/Volumes/My Shared Files/kit/setup.sh"`: setup deletes the saved account (`vm/kit/setup-finished`) and agent transport (`vm/agent-transport`) when it starts, and they come back only once `setup.sh` finishes.

## VM set up under the old label

A VM set up before the harness moved here runs its agent as `dev.hloth.nativenote.power-loss-agent`. Once, delete `vm/kit/dev.hloth.nativenote.power-loss-agent.plist` from the data folder, then in a [setup session](#shell-in-the-vm) run this before `setup.sh`:

```sh
sudo launchctl bootout system/dev.hloth.nativenote.power-loss-agent
sudo rm /Library/LaunchDaemons/dev.hloth.nativenote.power-loss-agent.plist
```
