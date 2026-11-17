#!/usr/bin/env bash
set -euo pipefail

canonical_host="x86_64-unknown-linux-gnu"
# shellcheck source=server-cross.sh
source "$(dirname "$0")/server-cross.sh"

pack_reproducibly() {
	local tarball="$1" dir="$2"
	shift 2
	if [[ "$(uname -s)" == Darwin ]]; then
		(cd "$dir" && TZ=UTC /usr/bin/touch -t "$(/bin/date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)" "$@")
		/usr/bin/tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata --no-acls --no-fflags -C "$dir" -cf - "$@" | /usr/bin/gzip -n -9 >"$tarball"
	else
		tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" -C "$dir" -cf - "$@" | gzip -n -9 >"$tarball"
	fi
}

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
version="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' Cargo.toml)"
[[ -n "$version" ]] || { echo "no workspace version in server/Cargo.toml" >&2; exit 1; }
sysroot="$(rustc --print sysroot)"
commit="$(rustc -vV | sed -n 's/^commit-hash: //p')"
host="$(rustc -vV | sed -n 's/^host: //p')"
[[ "$host" == "$canonical_host" ]] || echo "building on $host: only a build on $canonical_host matches a release" >&2
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
export CARGO_ENCODED_RUSTFLAGS SOURCE_DATE_EPOCH
export CARGO_TARGET_DIR="$work/target"

mkdir -p "$out"
for target in "${server_targets[@]}"; do
	cross_env "$target" "$work"
	env "${cross[@]}" "CFLAGS_${target//-/_}=${cflags[*]}" cargo build --release --locked -p native-note-server --target "$target"
	package="$work/package-$target"
	mkdir -p "$package"
	binary="$work/target/$target/release/native-note-server"
	if LC_ALL=C grep -aqF -e "$root" -e "$cargo_home" -e "$sysroot" -e "$work" "$binary"; then
		echo "a local path survived into the $target binary, so no other host can reproduce it" >&2
		exit 1
	fi
	check_arm_cpu "$target" "$binary"
	install -m 0755 "$binary" "$package/native-note-server"
	install -m 0644 "$root/server/native-note-server.service" "$package/native-note-server.service"
	pack_reproducibly "$out/native-note-server-$version-$target.tar.gz" "$package" native-note-server native-note-server.service
done
echo "built on $host"
cd "$out"
tarballs=("${server_targets[@]/#/native-note-server-$version-}")
sha256 "${tarballs[@]/%/.tar.gz}"
