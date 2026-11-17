# shellcheck shell=bash disable=SC2034

zig_version="0.16.0"
server_targets=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl armv7-unknown-linux-musleabihf arm-unknown-linux-musleabihf)

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) zig_host="aarch64-macos" zig_sha256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489" ;;
	Linux-x86_64) zig_host="x86_64-linux" zig_sha256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
	Linux-aarch64) zig_host="aarch64-linux" zig_sha256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
	*) echo "no pinned zig for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

install_zig() {
	local work="$1" archive="zig-$zig_host-$zig_version"
	curl -fsSLo "$work/$archive.tar.xz" "https://ziglang.org/download/$zig_version/$archive.tar.xz"
	echo "$zig_sha256  $work/$archive.tar.xz" | sha256 -c - >/dev/null
	tar -xJf "$work/$archive.tar.xz" -C "$work"
	zig="$work/$archive/zig"
	export ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" ZIG_LOCAL_CACHE_DIR="$work/zig-cache"
}

zig_target() {
	case "$1" in
		x86_64-unknown-linux-musl) echo "x86_64-linux-musl" ;;
		aarch64-unknown-linux-musl) echo "aarch64-linux-musl" ;;
		armv7-unknown-linux-musleabihf) echo "arm-linux-musleabihf -mcpu=generic+v7a+vfp3d16-neon" ;;
		arm-unknown-linux-musleabihf) echo "arm-linux-musleabihf -mcpu=arm1176jzf_s" ;;
		*) echo "no C toolchain for $1" >&2; return 1 ;;
	esac
}

cross_env() {
	local target="$1" work="$2" variable c_target
	c_target="$(zig_target "$target")"
	variable="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')"
	printf '#!/bin/sh\nfor arg do\n\tshift\n\tcase "$arg" in --target=*) ;; *) set -- "$@" "$arg" ;; esac\ndone\nexec "%s" cc -target %s "$@"\n' "$zig" "$c_target" >"$work/cc-$target"
	printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$zig" >"$work/ar"
	chmod +x "$work/cc-$target" "$work/ar"
	cross=("CC_${target//-/_}=$work/cc-$target" "AR_${target//-/_}=$work/ar" "CARGO_TARGET_${variable}_LINKER=rust-lld")
}

check_arm_cpu() {
	local target="$1" binary="$2" readobj attributes
	case "$target" in
		armv7-*) ;;
		arm-*) ;;
		*) return 0 ;;
	esac
	readobj="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin/llvm-readobj"
	attributes="$("$readobj" --arch-specific "$binary")"
	case "$target" in
		armv7-*) grep -A1 'TagName: CPU_arch$' <<<"$attributes" | grep -q 'Description: ARM v7$' && ! grep -q 'TagName: Advanced_SIMD_arch$' <<<"$attributes" ;;
		arm-*) grep -A1 'TagName: CPU_arch$' <<<"$attributes" | grep -qE 'Description: ARM v6(KZ)?$' ;;
	esac || { echo "the $target binary holds code for another ARM CPU" >&2; return 1; }
}
