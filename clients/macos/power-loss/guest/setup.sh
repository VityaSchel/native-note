#!/bin/sh
set -eu

volume=PowerLossLibrary
library_size=2147483648
home=/usr/local/libexec/native-note-power-loss
label=dev.hloth.nativenote.power-loss-agent
sudoers=/etc/sudoers.d/native-note-power-loss
kit=$(cd "$(dirname "$0")" && pwd)

fail() {
	echo "setup: $*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run this with sudo"
account=${SUDO_USER:-root}
[ "$account" != root ] || fail "run this with sudo from your account"
fdesetup status | grep -q "FileVault is Off" || fail "turn FileVault off in System Settings, then run this again"

status=0
"$kit/NativeNoteTypist" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "NativeNoteTypist does not start in this VM (exit $status)"

disk=
for candidate in $(diskutil list physical | awk '/^\/dev\/disk/ { print $1 }'); do
	size=$(diskutil info -plist "$candidate" | plutil -extract TotalSize raw -o - -)
	if [ "$size" = "$library_size" ]; then
		[ -z "$disk" ] || fail "found more than one 2 GB disk"
		disk=$candidate
	fi
done
[ -n "$disk" ] || fail "found no 2 GB library disk"
echo "setup: formatting $disk as $volume"
diskutil eraseDisk APFS "$volume" GPT "$disk"
mount_point=$(diskutil info -plist "$volume" | plutil -extract MountPoint raw -o - -)
mdutil -i off "$mount_point" >/dev/null 2>&1 || true
touch "$mount_point/.metadata_never_index"
mkdir -p "$mount_point/.fseventsd"
touch "$mount_point/.fseventsd/no_log"
defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true

echo "setup: keeping the VM awake and off automatic updates"
pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false

echo "setup: allowing SSH with the harness key for $account"
user_home=$(dscl . -read "/Users/$account" NFSHomeDirectory | awk '{ print $2 }')
install -d -m 0700 -o "$account" "$user_home/.ssh"
keys="$user_home/.ssh/authorized_keys"
touch "$keys"
grep -qxF "$(cat "$kit/power-loss.pub")" "$keys" || cat "$kit/power-loss.pub" >>"$keys"
chown "$account" "$keys"
chmod 0600 "$keys"
sh "$kit/allow-agent.sh" "$account" "$home/start-agent.sh" "$sudoers"
launchctl enable system/com.openssh.sshd
launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true

echo "setup: starting the agent"
log=$(plutil -extract StandardErrorPath raw -o - "$kit/$label.plist")
sh "$kit/install-agent.sh" "$home/start-agent.sh" "/Library/LaunchDaemons/$label.plist" "$log"

printf '%s\n' "$account" >"$kit/setup-finished"
echo "setup: done. The harness now checks the agent and shuts the VM down."
