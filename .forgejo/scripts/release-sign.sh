#!/usr/bin/env bash
set -euo pipefail

usage="usage: release-sign.sh <tag> <CI's native-note-server-<tag> artifact, as a zip or a directory>"
tag="${1:?$usage}"
artifact="${2:?$usage}"
root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
key="$(git -C "$root" config user.signingkey)" || { echo "set git's user.signingkey to the GPG key that signs releases" >&2; exit 1; }
git -C "$root" verify-tag "$tag" >/dev/null 2>&1 || { echo "$tag is not a tag with a good signature" >&2; exit 1; }
commit="$(git -C "$root" rev-parse "$tag^{commit}")"
out="$root/releases/$tag"
notes="$root/releases/$tag-notes.md"
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
zips=("native-note-$tag-macos-arm64.zip" "native-note-$tag-macos-x86_64.zip")
for zip in "${zips[@]}"; do
	[[ -f "$root/releases/$zip" ]] || { echo "releases/$zip is missing: build it with macos-release.sh $tag" >&2; exit 1; }
done

git -C "$root" worktree add --detach "$work/source" "$tag" >/dev/null
"$work/source/.forgejo/scripts/server-release.sh"
for binary in "$ci"/native-note-server-linux-*; do
	[[ -e "$work/source/releases/$(basename "$binary")" ]] || { echo "CI built $(basename "$binary"), which $tag does not" >&2; exit 1; }
done
for built in "$work/source/releases/"native-note-server-linux-*; do
	cmp -s "$built" "$ci/$(basename "$built")" || { echo "CI's $(basename "$built") is missing or differs from this Mac's build" >&2; exit 1; }
done
"$root/.forgejo/scripts/macos-build.sh" "$commit" >/dev/null
"$root/.forgejo/scripts/macos-verify.sh" "${zips[@]/#/$root/releases/}"

rm -rf "$out"
mkdir -p "$out"
for built in "$work/source/releases/"native-note-server-linux-*; do
	install -m 0755 "$built" "$out/$(basename "$built")"
done
for zip in "${zips[@]}"; do
	cp "$root/releases/$zip" "$out/$zip"
done
xcode="$(unzip -p "$out/${zips[0]}" 'Native Note.app/Contents/Info.plist' | plutil -extract DTXcodeBuild raw -o - -)"

{
	(cd "$out" && sha256sum native-note-server-linux-* native-note-v*.zip | LC_ALL=C sort -k 2)
	echo "built $commit with Xcode $xcode"
} >"$work/SHA256SUMS"
gpg --local-user "$key" --clearsign --output "$work/SHA256SUMS.asc" "$work/SHA256SUMS"
gpg --output - --decrypt "$work/SHA256SUMS.asc" | grep -E '^[0-9a-f]{64}  ' | (cd "$out" && sha256sum -c -)
{
	printf -- '---\n\n<details>\n<summary>PGP signature</summary>\n\n```\n'
	cat "$work/SHA256SUMS.asc"
	printf '```\n\n> Builds are [reproducible](https://git.hloth.dev/hloth/native-note/src/branch/main/BUILD.md).\n\n</details>\n'
} >"$notes"
echo "every $tag file matches this Mac's build; upload releases/$tag/ and end the release notes with releases/$tag-notes.md"
