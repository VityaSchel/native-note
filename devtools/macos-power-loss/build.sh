#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --product power-loss >&2
swift build -c release --product power-loss-agent >&2
swift build -c release --product power-loss-flush-probe >&2
swift build -c release --package-path ../../clients/macos/native-note-kit --product NativeNoteTypist >&2
bin="$(swift build -c release --show-bin-path)"
typist_bin="$(swift build -c release --package-path ../../clients/macos/native-note-kit --show-bin-path)"

guest="$bin/guest"
mkdir -p "$guest"
cp -f "$bin/power-loss-agent" "$bin/power-loss-flush-probe" "$typist_bin/NativeNoteTypist" guest/* "$guest/"
ditto "$typist_bin/SQLCipher.framework" "$guest/SQLCipher.framework"

codesign --sign - --force --entitlements PowerLoss.entitlements "$bin/power-loss" >&2
echo "$bin/power-loss"
