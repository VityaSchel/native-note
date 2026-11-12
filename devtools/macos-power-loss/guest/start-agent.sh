#!/bin/sh
kit=/private/var/native-note-power-loss/kit

kit_is_mounted() {
	mount | grep -q " on $kit ("
}

mkdir -p "$kit"
failure_reported=
until kit_is_mounted; do
	if ! failure=$(mount_virtiofs power-loss-kit "$kit" 2>&1); then
		[ -n "$failure_reported" ] || echo "start-agent: $(date -u +%Y-%m-%dT%H:%M:%SZ) cannot mount the kit, retrying every second: $failure" >&2
		failure_reported=yes
		sleep 1
	fi
done
exec "$kit/power-loss-agent"
