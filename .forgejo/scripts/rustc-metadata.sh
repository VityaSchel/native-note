#!/usr/bin/env bash
set -euo pipefail

rustc=$1
shift
args=("$@")
target=
metadata_at=-1
key=()
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
		--target) target=${args[i + 1]} ;;
		--target=*) target=${args[i]#--target=} ;;
		--crate-name | --crate-type | --cfg | --edition) key+=("${args[i]}" "${args[i + 1]}") ;;
		-C) [[ ${args[i + 1]} == metadata=* ]] && metadata_at=$((i + 1)) ;;
	esac
done
if [[ -n $target && $metadata_at -ge 0 ]]; then
	key+=("${CARGO_PKG_NAME:-}" "${CARGO_PKG_VERSION:-}" "$target")
	if command -v sha256sum >/dev/null; then hash=(sha256sum); else hash=(shasum -a 256); fi
	args[metadata_at]="metadata=$(printf '%s\n' "${key[@]}" | "${hash[@]}" | cut -c 1-16)"
fi
exec "$rustc" "${args[@]}"
