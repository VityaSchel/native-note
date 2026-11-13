#!/bin/sh
kit=/private/var/native-note-power-loss/kit
attempts=30

kit_is_mounted() {
	mount | grep -q " on $kit ("
}

now() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}

mkdir -p "$kit"
failure_reported=
attempt=0
until kit_is_mounted; do
	if [ "$attempt" -ge "$attempts" ]; then
		echo "start-agent: $(now) the kit is not mounted after $attempts attempts, giving up" >&2
		exit 1
	fi
	[ "$attempt" -eq 0 ] || sleep 1
	attempt=$((attempt + 1))
	if ! failure=$(mount_virtiofs power-loss-kit "$kit" 2>&1); then
		[ -n "$failure_reported" ] || echo "start-agent: $(now) cannot mount the kit, retrying every second: $failure" >&2
		failure_reported=yes
	fi
done
exec "$kit/power-loss-agent"
