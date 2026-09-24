#!/usr/bin/env bash
set -euo pipefail

rustup_version="1.29.0"
rustup_sha256="4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10"

cd "$(dirname "$0")/../.."

command -v cc >/dev/null 2>&1 || {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -y
	apt-get install -y --no-install-recommends gcc libc6-dev
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
installer="$workdir/rustup-init"
curl -fsSLo "$installer" \
	"https://static.rust-lang.org/rustup/archive/${rustup_version}/x86_64-unknown-linux-gnu/rustup-init"
echo "${rustup_sha256}  ${installer}" | sha256sum -c -
chmod +x "$installer"
"$installer" -q -y --no-modify-path --profile minimal --default-toolchain none
echo "$CARGO_HOME/bin" >> "$GITHUB_PATH"

"$CARGO_HOME/bin/rustup" --quiet show active-toolchain
