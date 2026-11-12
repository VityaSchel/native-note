#!/bin/sh
set -eu

kit=$(cd "$(dirname "$0")" && pwd)
label=dev.hloth.devtools.native-note-power-loss-test
launcher=/usr/local/libexec/native-note-power-loss/start-agent.sh
library_volume=PowerLossLibrary
library_disk_bytes=2147483648

fail() {
	echo "setup: $*" >&2
	exit 1
}

require_root_without_filevault() {
	[ "$(id -u)" -eq 0 ] || fail "run this with sudo"
	fdesetup status | grep -q "FileVault is Off" || fail "turn FileVault off in System Settings, then run this again"
}

require_typist_to_start() {
	status=0
	"$kit/NativeNoteTypist" >/dev/null 2>&1 || status=$?
	[ "$status" -eq 2 ] || fail "NativeNoteTypist does not start in this VM (exit $status)"
}

library_disk() {
	found=
	for disk in $(diskutil list physical | awk '/^\/dev\/disk/ { print $1 }'); do
		size=$(diskutil info -plist "$disk" | plutil -extract TotalSize raw -o - -)
		[ "$size" = "$library_disk_bytes" ] || continue
		[ -z "$found" ] || fail "found more than one 2 GB disk"
		found=$disk
	done
	[ -n "$found" ] || fail "found no 2 GB library disk"
	echo "$found"
}

format_library_disk() {
	disk=$(library_disk)
	echo "setup: formatting $disk as $library_volume"
	diskutil eraseDisk APFS "$library_volume" GPT "$disk"
	mount_point=$(diskutil info -plist "$library_volume" | plutil -extract MountPoint raw -o - -)
	mdutil -i off "$mount_point" >/dev/null 2>&1 || true
	touch "$mount_point/.metadata_never_index"
	mkdir -p "$mount_point/.fseventsd"
	touch "$mount_point/.fseventsd/no_log"
	defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true
}

keep_awake_without_updates() {
	echo "setup: keeping the VM awake and off automatic updates"
	pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null
	defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
	defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
}

start_agent() {
	echo "setup: starting the agent"
	log=$(plutil -extract StandardErrorPath raw -o - "$kit/$label.plist")
	sh "$kit/install-agent.sh" "$launcher" "/Library/LaunchDaemons/$label.plist" "$log"
}

require_root_without_filevault
require_typist_to_start
format_library_disk
keep_awake_without_updates
start_agent
touch "$kit/setup-finished"
echo "setup: done. The harness now checks the agent and shuts the VM down."
