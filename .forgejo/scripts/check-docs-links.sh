#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

errors=0

anchors_of() {
	awk '/^(```|~~~)/ { fenced = !fenced; next } !fenced' "$1" \
		| grep -E '^#{1,6} ' \
		| sed 's/^#* //' \
		| tr '[:upper:]' '[:lower:]' \
		| sed 's/[^a-z0-9 _-]//g; s/ /-/g'
}

check_link() {
	local doc="$1" link="$2" dir target anchor path
	dir="$(dirname "$doc")"

	case "$link" in
		http*|mailto:*|'') return 0 ;;
	esac

	target="${link%%#*}"
	anchor=""
	case "$link" in
		*'#'*) anchor="$(printf '%s' "${link#*#}" | tr '[:upper:]' '[:lower:]')" ;;
	esac

	if [ -n "$target" ]; then
		path="$dir/$target"
		if [ ! -e "$path" ]; then
			echo "$doc -> $link (no such file)"
			errors=$((errors + 1))
			return 0
		fi
	else
		path="$doc"
	fi

	case "$path" in
		*.md) ;;
		*) return 0 ;;
	esac

	if [ -n "$anchor" ] && ! anchors_of "$path" | grep -qx "$anchor"; then
		echo "$doc -> $link (no such anchor)"
		errors=$((errors + 1))
	fi
}

docs="$(git ls-files '*.md')"
[ -n "$docs" ] || { echo "::error::git listed no documentation files"; exit 1; }

while IFS= read -r doc; do
	while IFS= read -r link; do
		check_link "$doc" "$link"
	done < <(grep -oE '\]\([^) ]+\)' "$doc" | sed 's/^](//; s/)$//')
done <<<"$docs"

if [ "$errors" -ne 0 ]; then
	echo "::error::$errors broken documentation link(s)"
	exit 1
fi

echo "documentation links ok"
