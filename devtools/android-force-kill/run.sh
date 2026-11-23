#!/bin/bash
set -euo pipefail

readonly rounds=${1:-12}
readonly serial=${ANDROID_SERIAL:?set ANDROID_SERIAL to the device}
readonly adb=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
readonly runner=dev.hloth.nativenote.debug.test/androidx.test.runner.AndroidJUnitRunner
readonly typist=dev.hloth.nativenote.endurance.ForceKillTypist

device() {
	"$adb" -s "$serial" "$@"
}

failed=0
for round in $(seq 1 "$rounds"); do
	device shell am instrument -w -e forceKill type -e class "$typist#type" "$runner" >/dev/null 2>&1 &
	typing=$!
	sleep "$(awk -v r="$RANDOM" 'BEGIN { printf "%.2f", 2 + (r % 3000) / 1000 }')"
	device shell am force-stop dev.hloth.nativenote.debug
	wait "$typing" || true
	device logcat -c
	result=$(device shell am instrument -w -e forceKill verify -e class "$typist#verify" "$runner")
	line=$(device logcat -d -s NativeNoteForceKill:I | grep -o 'typed .*' || true)
	if grep -q '^OK (1 test)' <<<"$result"; then
		echo "round $round: $line"
	else
		failed=1
		echo "round $round FAILED: $line"
		grep -E 'Error|Assertion|expected' <<<"$result" || echo "$result"
	fi
done
exit "$failed"
