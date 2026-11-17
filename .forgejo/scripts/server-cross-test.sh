#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=server-cross.sh
source "$(dirname "$0")/server-cross.sh"
root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
install_zig "$work"

cd "$root/server"
for target in "${@:-${server_targets[@]}}"; do
	cross_env "$target" "$work"
	env "${cross[@]}" "CFLAGS_${target//-/_}=-fno-sanitize=undefined" CARGO_PROFILE_DEV_OPT_LEVEL=3 cargo test --locked --target "$target"
done
