#!/bin/sh
set -eu

[ "$#" -eq 3 ] || { echo "usage: install-agent.sh <launcher> <launch daemon> <log>" >&2; exit 2; }
kit=$(cd "$(dirname "$0")" && pwd)
launcher=$1
daemon=$2
log=$3
label=$(basename "$daemon" .plist)

install -d -m 0755 "$(dirname "$launcher")"
install -m 0755 "$kit/start-agent.sh" "$launcher"
install -m 0644 "$kit/$label.plist" "$daemon"
: >"$log"
launchctl bootstrap system "$daemon" 2>/dev/null || launchctl kickstart -k "system/$label"
