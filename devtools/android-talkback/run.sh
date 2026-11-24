#!/bin/bash
set -euo pipefail

readonly serial=${ANDROID_SERIAL:?set ANDROID_SERIAL to an emulator with TalkBack}
readonly adb=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
readonly port=${PORT:-18460}
readonly repo=$(cd "$(dirname "$0")/../.." && pwd)
readonly reports=$HOME/Library/Developer/native-note-devtools/android-talkback

case $serial in
emulator-*) ;;
*) echo "this changes accessibility settings, so it only runs on an emulator" >&2; exit 1 ;;
esac
"$adb" -s "$serial" wait-for-device shell 'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done'
(cd "$repo/server" && cargo build --quiet --locked -p native-note-server)
(cd "$repo/clients/android" && ./gradlew --console=plain -q assembleDebug)

work=$(mktemp -d)
server=
cleanup() {
	[ -z "$server" ] || kill "$server" 2>/dev/null || true
	"$adb" -s "$serial" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
	"$adb" -s "$serial" uninstall dev.hloth.devtools.speech >/dev/null 2>&1 || true
	rm -rf "${work:?}"
}
trap cleanup EXIT

mkdir "$work/data" && mkdir -p "$reports"
"$repo/server/target/debug/native-note-server" "127.0.0.1:$port" "$work/data" 2>"$work/server.log" >/dev/null &
server=$!
for _ in $(seq 1 100); do
	grep -q 'event=listening' "$work/server.log" && break
	sleep 0.1
done
grep -q 'event=listening' "$work/server.log" || { cat "$work/server.log" >&2; exit 1; }
"$adb" -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null

"$(dirname "$0")/build-speech.sh" "$work/speech.apk"
"$adb" -s "$serial" install -r "$work/speech.apk" >/dev/null
"$adb" -s "$serial" install -r -t "$repo/clients/android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null
REPORT="$reports/report.txt" bun "$(dirname "$0")/run.ts" "$serial" "http://127.0.0.1:$port" "$(tr -d '[:space:]' <"$work/data/api-key")"
