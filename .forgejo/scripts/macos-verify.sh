#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly root=/private/tmp/native-note-release
readonly exe="Contents/MacOS/Native Note"
readonly car="Contents/Resources/Assets.car"
scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
team_id=$(sed -n 's/^readonly team_id=//p' "$scripts/macos-sign.sh")
readonly scripts team_id
readonly team_keys=(com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups)
work=$(mktemp -d)
readonly work
trap 'rm -rf "$work"' EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

[ $# -gt 0 ] || { echo "usage: macos-verify.sh <release zip>..." >&2; exit 2; }
[ -f "$root/commit" ] || { echo "no build in $root: run macos-build.sh first" >&2; exit 1; }
built=$(cut -c 1-12 "$root/commit")
readonly built
for zip in "$@"; do
	cp "$zip" "$work/$(basename "$zip")"
done

entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null; }
car_content() {
	assetutil --info "$1" | sed -E '/"(Timestamp|SHA1Digest)"/d; s/_[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}-[0-9]+-[0-9A-F]{16}\.png/.png/'
	perl -0777 -MDigest::SHA=sha256_hex -ne '
		s/_[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}-\d+-[0-9A-F]{16}\.png\0*/"\0" x length $&/ge;
		while (/ISTC/g) {
			my ($tlv, $data) = unpack "x168 V x8 V", substr $_, pos() - 4, 184;
			print sha256_hex(substr $_, pos() - 4, 184 + $tlv + $data), "\n";
		}' "$1" | sort
}
listing() {
	(cd "$1" && find . | LC_ALL=C sort | while IFS= read -r path; do
		printf '%s %s %s\n' "$(stat -f %p "$path")" "$(test -f "$path" && shasum -a 256 < "$path")" "$path"
	done)
}

verify() {
	local name=$1 dir="$work/${1%.zip}" published rebuilt arch bundle offset size key assessment
	local rebuilt_zip="$root/out/$name"
	if [ ! -f "$rebuilt_zip" ]; then
		echo "✗ the build of $built has no $name, only $(cd "$root/out" && find . -name '*.zip' | sed 's#^\./##' | sort | paste -s -d ' ' -)" >&2
		return 1
	fi
	ditto -x -k "$work/$name" "$dir/published"
	ditto -x -k "$rebuilt_zip" "$dir/rebuilt"
	published="$dir/published/Native Note.app"
	rebuilt="$dir/rebuilt/Native Note.app"
	arch=$(lipo -archs "$rebuilt/$exe")
	bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$rebuilt/Contents/Info.plist")

	entitlements "$published" > "$dir/published.entitlements"
	entitlements "$rebuilt" > "$dir/rebuilt.entitlements"
	grant() { plutil -extract "$1" raw -o - "$dir/published.entitlements" 2>/dev/null; }
	if [ "$(grant com\\.apple\\.application-identifier)" != "$team_id.$bundle" ] || [ "$(grant com\\.apple\\.developer\\.team-identifier)" != "$team_id" ] ||
		[ "$(grant keychain-access-groups.0)" != "$team_id.$bundle" ] || grant keychain-access-groups.1 > /dev/null; then
		echo "✗ $name is not entitled to team $team_id's keychain group for $bundle alone" >&2
		return 1
	fi
	for key in "${team_keys[@]}"; do
		plutil -remove "${key//./\\.}" "$dir/published.entitlements"
	done
	if ! diff -q <(plutil -convert xml1 -o - "$dir/published.entitlements") <(plutil -convert xml1 -o - "$dir/rebuilt.entitlements") > /dev/null ||
		! [[ $(codesign -dv "$published" 2>&1) =~ flags=[^[:space:]]*runtime ]]; then
		echo "✗ $name is not signed with the hardened runtime and the entitlements of this build plus team $team_id's" >&2
		return 1
	fi

	read -r offset size < <(otool -l "$published/$exe" | awk '/cmd LC_CODE_SIGNATURE/ { f = 1 } f && /dataoff/ { o = $2 } f && /datasize/ { print o, $2; exit }')
	cp "$rebuilt/$exe" "$dir/unsigned"
	codesign --remove-signature "$dir/unsigned"
	xcrun codesign_allocate -i "$dir/unsigned" -a "$arch" "$size" -o "$dir/grafted"
	dd if="$published/$exe" of="$dir/grafted" bs=1 skip="$offset" seek="$offset" count="$size" conv=notrunc 2>/dev/null
	cat "$dir/grafted" > "$rebuilt/$exe"
	rm -rf "$rebuilt/Contents/_CodeSignature" "$rebuilt/Contents/CodeResources"
	ditto "$published/Contents/_CodeSignature" "$rebuilt/Contents/_CodeSignature"
	for signed in CodeResources embedded.provisionprofile; do
		if [ -e "$published/Contents/$signed" ]; then
			ditto "$published/Contents/$signed" "$rebuilt/Contents/$signed"
		fi
	done

	if [ -e "$published/$car" ] && [ -e "$rebuilt/$car" ] && [ "$(stat -f %z "$published/$car")" = "$(stat -f %z "$rebuilt/$car")" ] &&
		diff -q <(car_content "$published/$car") <(car_content "$rebuilt/$car") > /dev/null; then
		cat "$published/$car" > "$rebuilt/$car"
	fi

	if ! diff <(listing "$dir/published") <(listing "$dir/rebuilt") || ! codesign --verify --deep --strict "$published"; then
		echo "✗ $name does not match the build of $built" >&2
		return 1
	fi
	assessment=$(spctl --assess -vv "$published" 2>&1) || true
	if [[ $assessment != *"source=Notarized Developer ID"* ]] || ! [[ $assessment =~ origin=(Developer\ ID\ Application:\ .*\($team_id\)) ]]; then
		echo "✗ $name is not notarized under team $team_id: $assessment" >&2
		return 1
	fi
	echo "✓ $name is the build of $built plus its own signature, notarized for ${BASH_REMATCH[1]}"
}

status=0
for zip in "$@"; do
	verify "$(basename "$zip")" || status=1
done
exit "$status"
