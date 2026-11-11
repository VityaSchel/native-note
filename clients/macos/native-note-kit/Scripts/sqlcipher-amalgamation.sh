#!/usr/bin/env bash
set -euo pipefail

version="4.17.0"
commit="810db22f575ee7cf94ea96a3e91622b5fcece3dc"
sqlite3_c_sha256="8adaff6b464052a74e7adaa3cfa2725400f48eca68f47856fa806eaf30bdf2c9"
sqlite3_h_sha256="e564d0492e7556a8ad2f30c8ec645b5a6abb89f32f7b40465a3032d937596401"

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

matches_pins() {
	printf '%s  %s\n%s  %s\n' "$sqlite3_c_sha256" "$1" "$sqlite3_h_sha256" "$2" | sha256 -c - >/dev/null 2>&1
}

kit="$(cd -P "$(dirname "$0")/.." && pwd -P)"
sqlcipher="$kit/sqlcipher"
target="$kit/Sources/SQLCipher"

if matches_pins "$target/sqlite3.c" "$target/include/sqlite3.h"; then
	exit 0
fi

if [[ ! -e "$sqlcipher/.git" ]]; then
	git -C "$kit" submodule update --init --depth 1 -- sqlcipher
fi
if [[ "$(git -C "$sqlcipher" rev-parse HEAD)" != "$commit" ]]; then
	echo "$sqlcipher is not at SQLCipher v$version ($commit): run git submodule update" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$work" && "$sqlcipher/configure" --disable-tcl >/dev/null && make sqlite3.c >/dev/null)

if ! matches_pins "$work/sqlite3.c" "$work/sqlite3.h"; then
	echo "the generated amalgamation differs from the pinned hashes:" >&2
	sha256 "$work/sqlite3.c" "$work/sqlite3.h" >&2
	exit 1
fi
cp "$work/sqlite3.c" "$target/sqlite3.c"
cp "$work/sqlite3.h" "$target/include/sqlite3.h"
