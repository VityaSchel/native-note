#!/bin/bash
set -euo pipefail

readonly serial=${ANDROID_SERIAL:?set ANDROID_SERIAL to the device}
readonly adb=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
readonly repo=$(cd "$(dirname "$0")/../.." && pwd)
readonly count=${SERVERS:-21}
readonly base_port=${BASE_PORT:-18300}

(cd "$repo/server" && cargo build --quiet --locked -p native-note-server)

work=$(mktemp -d)
pids=()
cleanup() {
	for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
	for index in $(seq 0 $((count - 1))); do "$adb" -s "$serial" reverse --remove "tcp:$((base_port + index))" >/dev/null 2>&1 || true; done
	rm -rf "${work:?}"
}
trap cleanup EXIT

servers=()
for index in $(seq 0 $((count - 1))); do
	port=$((base_port + index))
	data="$work/server-$index"
	mkdir "$data"
	"$repo/server/target/debug/native-note-server" "127.0.0.1:$port" "$data" 2>"$data.log" >/dev/null &
	pids+=("$!")
	for _ in $(seq 1 100); do
		grep -q 'event=listening' "$data.log" && break
		sleep 0.1
	done
	grep -q 'event=listening' "$data.log" || { cat "$data.log"; exit 1; }
	"$adb" -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null
	servers+=("http://127.0.0.1:$port/|$(tr -d '[:space:]' <"$data/api-key")")
done

cd "$repo/clients/android"
ANDROID_SERIAL=$serial ./gradlew --console=plain connectedDebugAndroidTest \
	-Pandroid.testInstrumentationRunnerArguments.class=dev.hloth.nativenote.sync.ServerSyncTest,dev.hloth.nativenote.sync.RecoveryServerTest,dev.hloth.nativenote.ui.SyncSetupUiTest,dev.hloth.nativenote.threatmodel.ServerViewTest \
	-Pandroid.testInstrumentationRunnerArguments.syncServers="$(IFS=,; echo "${servers[*]}")" \
	"$@"
