#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
typist_package=../../clients/macos/native-note-kit

build_release() {
	swift build -c release "$@" >&2
}

build_release --product power-loss
build_release --product power-loss-agent
"$typist_package/Scripts/sqlcipher-amalgamation.sh" >&2
build_release --package-path "$typist_package" --product NativeNoteTypist
bin="$(swift build -c release --show-bin-path)"
typist_bin="$(swift build -c release --package-path "$typist_package" --show-bin-path)"

guest_kit="${bin:?}/guest"
rm -rf "$guest_kit"
mkdir -p "$guest_kit"
cp -f "$bin/power-loss-agent" "$typist_bin/NativeNoteTypist" guest/* "$guest_kit/"

codesign --sign - --force --entitlements PowerLoss.entitlements "$bin/power-loss" >&2
echo "$bin/power-loss"
