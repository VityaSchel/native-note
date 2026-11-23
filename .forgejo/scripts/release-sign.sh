#!/usr/bin/env bash
set -euo pipefail

usage="usage: ANDROID_KEYSTORE=<release keystore> ANDROID_UPLOAD_KEYSTORE=<Play upload keystore> release-sign.sh <tag> <CI's native-note-server-<tag> artifact> <CI's native-note-android-<tag> artifact>, each a zip or a directory"
tag="${1:?$usage}"
server_artifact="${2:?$usage}"
android_artifact="${3:?$usage}"
: "${ANDROID_KEYSTORE:?$usage}" "${ANDROID_UPLOAD_KEYSTORE:?$usage}"
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

unpacked() {
	if [[ -f "$1" ]]; then
		mkdir "$work/$2"
		unzip -q "$1" -d "$work/$2"
		echo "$work/$2"
	else
		(cd "$1" && pwd -P)
	fi
}
ci="$(unpacked "$server_artifact" server)"
ci_android="$(unpacked "$android_artifact" android)"
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
"$root/.forgejo/scripts/android-build.sh" "$commit" >/dev/null
android=/tmp/native-note-android/out
apk="native-note-$tag-android-unsigned.apk"
aab="native-note-$tag-android-unsigned.aab"
[[ "$(cd "$android" && ls)" == "$(printf '%s\n' "$aab" "$apk")" ]] || { echo "this Mac's Android build of $tag is not $apk and $aab" >&2; exit 1; }
[[ "$(cd "$ci_android" && ls)" == "$(cd "$android" && ls)" ]] || { echo "CI's Android artifact is not $apk and $aab" >&2; exit 1; }
for built in "$apk" "$aab"; do
	cmp -s "$android/$built" "$ci_android/$built" || { echo "CI's $built differs from this Mac's build" >&2; exit 1; }
done
"$root/.forgejo/scripts/android-sign.sh" "$android/$apk" "$android/$aab" "$work/signed"
"$root/.forgejo/scripts/android-verify.sh" "$work/signed/native-note-$tag-android.apk"

rm -rf "$out"
mkdir -p "$out"
for built in "$work/source/releases/"native-note-server-linux-*; do
	install -m 0755 "$built" "$out/$(basename "$built")"
done
for zip in "${zips[@]}"; do
	cp "$root/releases/$zip" "$out/$zip"
done
cp "$work/signed/native-note-$tag-android.apk" "$out/"
cp "$work/signed/native-note-$tag-android-play.aab" "$root/releases/"
xcode="$(unzip -p "$out/${zips[0]}" 'Native Note.app/Contents/Info.plist' | plutil -extract DTXcodeBuild raw -o - -)"

{
	(cd "$out" && sha256sum native-note-server-linux-* native-note-v*.zip native-note-v*.apk | LC_ALL=C sort -k 2)
	echo "built $commit with Xcode $xcode"
} >"$work/SHA256SUMS"
gpg --local-user "$key" --clearsign --output "$work/SHA256SUMS.asc" "$work/SHA256SUMS"
gpg --output - --decrypt "$work/SHA256SUMS.asc" | grep -E '^[0-9a-f]{64}  ' | (cd "$out" && sha256sum -c -)
{
	printf -- '---\n\n<details>\n<summary>PGP signature</summary>\n\n```\n'
	cat "$work/SHA256SUMS.asc"
	printf '```\n\n> Builds are [reproducible](https://git.hloth.dev/hloth/native-note/src/branch/main/BUILD.md).\n\n</details>\n'
} >"$notes"
echo "every $tag file matches this Mac's build; upload releases/$tag/ and end the release notes with releases/$tag-notes.md, then upload releases/native-note-$tag-android-play.aab to Google Play"
