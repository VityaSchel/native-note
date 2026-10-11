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

root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
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
export CARGO_ENCODED_RUSTFLAGS="$(IFS=$'\x1f'; echo "${rustflags[*]}")"
export CARGO_TARGET_DIR="$work/target"
export SOURCE_DATE_EPOCH="$(git -C "$root" log -1 --format=%ct)"
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
	cp "$work/target/$target/release/native-note-server" "$out/native-note-server-$target"
done
# Cargo hashes `rustc -vV`, which names the build host, into every crate, so only builds on the same host match.
echo "built on $(rustc -vV | sed -n 's/^host: //p')"
cd "$out"
sha256 "${targets[@]/#/native-note-server-}"
