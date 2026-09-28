#!/bin/sh
kit=/private/var/native-note-power-loss/kit
mkdir -p "$kit"
reported=
until mount | grep -q " on $kit ("; do
	if ! failure=$(mount_virtiofs power-loss-kit "$kit" 2>&1); then
		[ -n "$reported" ] || echo "start-agent: $(date -u +%Y-%m-%dT%H:%M:%SZ) cannot mount the kit, retrying every second: $failure" >&2
		reported=yes
		sleep 1
	fi
done
exec "$kit/power-loss-agent" --kit "$kit" "$@"
