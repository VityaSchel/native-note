#!/bin/bash
set -euo pipefail

readonly serial=${ANDROID_SERIAL:?set ANDROID_SERIAL to the device}
readonly adb=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
readonly repo=$(cd "$(dirname "$0")/../.." && pwd)
readonly port=${CROSS_CLIENT_PORT:-18400}
readonly developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

(cd "$repo/server" && cargo build --quiet --locked -p native-note-server)

work=$(mktemp -d)
server_pid=
cleanup() {
	[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
	"$adb" -s "$serial" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
	rm -rf "${work:?}"
}
trap cleanup EXIT

mkdir "$work/server"
"$repo/server/target/debug/native-note-server" "127.0.0.1:$port" "$work/server" 2>"$work/server.log" >/dev/null &
server_pid=$!
for _ in $(seq 1 100); do
	grep -q 'event=listening' "$work/server.log" && break
	sleep 0.1
done
"$adb" -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null
readonly address="http://127.0.0.1:$port/"
api_key=$(tr -d '[:space:]' <"$work/server/api-key")

macos() {
	DEVELOPER_DIR=$developer_dir NATIVE_NOTE_CROSS_CLIENT=$1 NATIVE_NOTE_SERVER=$address NATIVE_NOTE_API_KEY=$api_key \
		NATIVE_NOTE_OUT="$work/macos.txt" NATIVE_NOTE_WORDS=${words:-} NATIVE_NOTE_EXPECT=${expect:-} \
		swift test --package-path "$repo/clients/macos/native-note-kit" --filter "CrossClientTests/$2"
}

echo "macOS writes a library"
macos write writesALibraryForAnotherClient
words=$(sed -n 1p "$work/macos.txt")
expect=$(sed -n 2p "$work/macos.txt")

echo "Android joins it, checks it and changes it"
"$adb" -s "$serial" logcat -c
(cd "$repo/clients/android" && ANDROID_SERIAL=$serial ./gradlew --console=plain -q connectedDebugAndroidTest \
	-Pandroid.testInstrumentationRunnerArguments.class=dev.hloth.nativenote.sync.CrossClientTest \
	-Pandroid.testInstrumentationRunnerArguments.crossServer="$address" \
	-Pandroid.testInstrumentationRunnerArguments.crossApiKey="$api_key" \
	-Pandroid.testInstrumentationRunnerArguments.crossWords="${words// /,}" \
	-Pandroid.testInstrumentationRunnerArguments.crossExpect="$expect")
expect=$("$adb" -s "$serial" logcat -d -s NativeNoteCrossClient:I | grep -o 'state [0-9a-f]*' | tail -1 | cut -d' ' -f2)
[ -n "$expect" ] || { echo "Android reported no state"; exit 1; }

echo "macOS joins again and sees Android's changes"
macos read readsWhatAnotherClientWrote
echo "converged on $expect"
