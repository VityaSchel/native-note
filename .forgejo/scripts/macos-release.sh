#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly notary_profile=native-note
source "$(dirname "${BASH_SOURCE[0]}")/macos-build.sh"
source "$(dirname "${BASH_SOURCE[0]}")/macos-sign.sh"

if [ -n "$(git -C "$repo" status --porcelain)" ]; then
	echo "commit or stash your changes first" >&2
	exit 1
fi

bundle=$(project_setting PRODUCT_BUNDLE_IDENTIFIER)
signer=$(signing_identity "Developer ID Application" -p codesigning)
if [ -z "$signer" ]; then
	echo "no valid Developer ID Application certificate of team $team_id in the keychain" >&2
	exit 1
fi
profile=$(provisioning_profile "$bundle" developer-id) || {
	echo "no Developer ID provisioning profile of team $team_id for $bundle: download it from the developer account into ~/Library/Developer/Xcode/UserData/Provisioning Profiles" >&2
	exit 1
}

version=$(project_setting MARKETING_VERSION)
for arch in "${architectures[@]}"; do
	if [ -e "$repo/releases/native-note-v$version-macos-$arch.zip" ]; then
		echo "$repo/releases/native-note-v$version-macos-$arch.zip already exists: set a new version in the project" >&2
		exit 1
	fi
done

lock_root
build
refuse_identifying_data

for arch in "${architectures[@]}"; do
	rm "$(zip_of "$arch")"
	sign "$(app "$arch")" "$signer" "$profile" "$bundle" "$arch"
	package "$arch"
	notarization=$(DEVELOPER_DIR="$developer_dir" xcrun notarytool submit "$(zip_of "$arch")" --keychain-profile "$notary_profile" --wait --output-format json) || true
	if [ "$(plutil -extract status raw -o - - <<< "$notarization" 2>/dev/null)" != Accepted ]; then
		rm "$root/out/"*.zip
		echo "notarization of the $arch app failed: $notarization" >&2
		exit 1
	fi
	rm "$(zip_of "$arch")"
	DEVELOPER_DIR="$developer_dir" xcrun stapler staple -q "$(app "$arch")"
	spctl --assess --type execute "$(app "$arch")"
	package "$arch"
done

mkdir -p "$repo/releases"
cp "$root/out/"*.zip "$repo/releases/"
(cd "$root/out" && shasum -a 256 -- *.zip)
echo "built $commit with Xcode $found into $root/out"
