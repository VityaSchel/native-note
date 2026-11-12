#!/usr/bin/env bash
set -euo pipefail

zig_version="0.16.0"
targets=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl)

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) zig_host="aarch64-macos" zig_sha256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489" ;;
	Linux-x86_64) zig_host="x86_64-linux" zig_sha256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
	Linux-aarch64) zig_host="aarch64-linux" zig_sha256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
	*) echo "no pinned zig for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

pack_reproducibly() {
	local tarball="$1" dir="$2"
	shift 2
	if tar --version 2>/dev/null | grep -q "GNU tar"; then
		tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" -C "$dir" -cf - "$@"
	else
		(cd "$dir" && TZ=UTC touch -t "$(date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)" "$@")
		tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata --no-acls --no-fflags -C "$dir" -cf - "$@"
	fi | gzip -n -9 >"$tarball"
}

root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
	echo "commit or stash every change first: a release is built from a commit only" >&2
	exit 1
fi
out="$root/releases"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

zig="zig-$zig_host-$zig_version"
curl -fsSLo "$work/$zig.tar.xz" "https://ziglang.org/download/$zig_version/$zig.tar.xz"
echo "$zig_sha256  $work/$zig.tar.xz" | sha256 -c - >/dev/null
tar -xJf "$work/$zig.tar.xz" -C "$work"

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
export CARGO_ENCODED_RUSTFLAGS SOURCE_DATE_EPOCH
export CARGO_TARGET_DIR="$work/target"
export ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" ZIG_LOCAL_CACHE_DIR="$work/zig-cache"

mkdir -p "$out"
for target in "${targets[@]}"; do
	arch="${target%%-*}"
	cc="$work/cc-$arch"
	printf '#!/bin/sh\nfor arg do\n\tshift\n\tcase "$arg" in --target=*) ;; *) set -- "$@" "$arg" ;; esac\ndone\nexec "%s" cc -target %s-linux-musl "$@"\n' "$work/$zig/zig" "$arch" >"$cc"
	printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$work/$zig/zig" >"$work/ar"
	chmod +x "$cc" "$work/ar"
	variable="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')"
	env "CC_${target//-/_}=$cc" "AR_${target//-/_}=$work/ar" "CFLAGS_${target//-/_}=${cflags[*]}" \
		"CARGO_TARGET_${variable}_LINKER=rust-lld" \
		cargo build --release --locked -p native-note-server --target "$target"
	package="$work/package-$target"
	mkdir -p "$package"
	install -m 0755 "$work/target/$target/release/native-note-server" "$package/native-note-server"
	install -m 0644 "$root/server/native-note-server.service" "$package/native-note-server.service"
	pack_reproducibly "$out/native-note-server-$target.tar.gz" "$package" native-note-server native-note-server.service
done
echo "built on $(rustc -vV | sed -n 's/^host: //p')"
cd "$out"
tarballs=("${targets[@]/#/native-note-server-}")
sha256 "${tarballs[@]/%/.tar.gz}"
