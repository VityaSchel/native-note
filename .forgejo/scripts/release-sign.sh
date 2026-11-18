#!/usr/bin/env bash
set -euo pipefail

usage="usage: release-sign.sh <tag> <CI's native-note-server-<tag> artifact, as a zip or a directory>"
tag="${1:?$usage}"
artifact="${2:?$usage}"
root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
key="$(git -C "$root" config user.signingkey)" || { echo "set git's user.signingkey to the GPG key that signs releases" >&2; exit 1; }
git -C "$root" verify-tag "$tag" >/dev/null 2>&1 || { echo "$tag is not a tag with a good signature" >&2; exit 1; }
out="$root/releases/$tag"
work="$(mktemp -d)"
cleanup() {
	git -C "$root" worktree remove --force "$work/source" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

if [[ -f "$artifact" ]]; then
	mkdir "$work/ci"
	unzip -q "$artifact" -d "$work/ci"
	ci="$work/ci"
else
	ci="$(cd "$artifact" && pwd -P)"
fi

git -C "$root" worktree add --detach "$work/source" "$tag" >/dev/null
"$work/source/.forgejo/scripts/server-release.sh"

rm -rf "$out"
mkdir -p "$out"
for binary in "$ci"/native-note-server-linux-*; do
	[[ -e "$work/source/releases/$(basename "$binary")" ]] || { echo "CI built $(basename "$binary"), which $tag does not" >&2; exit 1; }
done
for built in "$work/source/releases/"native-note-server-linux-*; do
	name="$(basename "$built")"
	cmp -s "$built" "$ci/$name" || { echo "CI's $name is missing or differs from this Mac's build" >&2; exit 1; }
	install -m 0755 "$built" "$out/$name"
done
for arch in arm64 x86_64; do
	zip="native-note-$tag-$arch.zip"
	[[ -f "$root/releases/$zip" ]] || { echo "releases/$zip is missing: build it with macos-release.sh $tag" >&2; exit 1; }
	cp "$root/releases/$zip" "$out/$zip"
done

(cd "$out" && sha256sum native-note-server-linux-* native-note-v*.zip | LC_ALL=C sort -k 2 >SHA256SUMS)
gpg --local-user "$key" --armor --detach-sign --output "$out/SHA256SUMS.asc" "$out/SHA256SUMS"
gpg --verify "$out/SHA256SUMS.asc" "$out/SHA256SUMS"
(cd "$out" && sha256sum -c SHA256SUMS)
echo "CI's binaries match this Mac's build; upload every file in releases/$tag to the $tag release"
