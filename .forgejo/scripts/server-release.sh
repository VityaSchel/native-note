#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=server-cross.sh
source "$(dirname "$0")/server-cross.sh"

root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
	echo "commit or stash every change first: a release is built from a commit only" >&2
	exit 1
fi
out="$root/releases"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

install_zig "$work"

cd "$root/server"
sysroot="$(rustc --print sysroot)"
commit="$(rustc -vV | sed -n 's/^commit-hash: //p')"
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
case "$root$cargo_home$sysroot$work" in
	*" "*) echo "paths with spaces cannot be remapped in CFLAGS" >&2; exit 1 ;;
esac
remaps=("$root=/native-note" "$cargo_home=/cargo" "$sysroot/lib/rustlib/src/rust=/rustc/$commit" "$work=/work")
rustflags=()
cflags=()
for remap in "${remaps[@]}"; do
	rustflags+=("--remap-path-prefix=$remap")
	cflags+=("-ffile-prefix-map=$remap")
done
CARGO_ENCODED_RUSTFLAGS="$(IFS=$'\x1f'; echo "${rustflags[*]}")"
SOURCE_DATE_EPOCH="$(git -C "$root" log -1 --format=%ct)"
RUSTC_WRAPPER="$root/.forgejo/scripts/rustc-metadata.sh"
export CARGO_ENCODED_RUSTFLAGS SOURCE_DATE_EPOCH RUSTC_WRAPPER
export CARGO_TARGET_DIR="$work/target"

mkdir -p "$out"
names=()
for target in "${server_targets[@]}"; do
	cross_env "$target" "$work"
	env "${cross[@]}" "CFLAGS_${target//-/_}=${cflags[*]}" cargo build --release --locked -p native-note-server --target "$target"
	binary="$work/target/$target/release/native-note-server"
	if LC_ALL=C grep -aqF -e "$root" -e "$cargo_home" -e "$sysroot" -e "$work" "$binary"; then
		echo "a local path survived into the $target binary, so no other host can reproduce it" >&2
		exit 1
	fi
	check_arm_cpu "$target" "$binary"
	"$(llvm_tool llvm-objcopy)" --remove-section=.comment "$binary"
	case "$target" in
		x86_64-*) machine=x86_64 ;;
		aarch64-*) machine=aarch64 ;;
		armv7-*) machine=armv7l ;;
		arm-*) machine=armv6l ;;
		*) echo "no uname -m name for $target" >&2; exit 1 ;;
	esac
	name="native-note-server-linux-$machine"
	install -m 0755 "$binary" "$out/$name"
	names+=("$name")
done
cd "$out"
sha256 "${names[@]}"
