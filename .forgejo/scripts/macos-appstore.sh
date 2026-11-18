#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

source "$(dirname "${BASH_SOURCE[0]}")/macos-build.sh"
source "$(dirname "${BASH_SOURCE[0]}")/macos-sign.sh"

readonly universal_app="$root/appstore/Native Note.app"

universal() {
	local arm intel binary relative
	arm=$(app arm64)
	intel=$(app x86_64)
	rm -rf "$root/appstore"
	mkdir "$root/appstore"
	ditto "$arm" "$universal_app"
	rm -rf "$universal_app/Contents/_CodeSignature"
	cmp -s "$arm/Contents/Info.plist" "$intel/Contents/Info.plist" || { echo "the arm64 and x86_64 apps have different Info.plist files" >&2; exit 1; }
	while IFS= read -r -d '' binary; do
		relative=${binary#"$arm/"}
		if file -b "$binary" | grep -q Mach-O; then
			lipo -create "$binary" "$intel/$relative" -output "$universal_app/$relative"
			[ "$(lipo -archs "$universal_app/$relative")" = "x86_64 arm64" ] || { echo "$relative is not arm64 and x86_64" >&2; exit 1; }
		fi
	done < <(find "$arm/Contents" -type f -not -path '*/_CodeSignature/*' -print0)
	xattr -cr "$universal_app"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	if [ -n "$(git -C "$repo" status --porcelain)" ]; then
		echo "commit or stash your changes first" >&2
		exit 1
	fi
	bundle=$(project_setting PRODUCT_BUNDLE_IDENTIFIER)
	version=$(project_setting MARKETING_VERSION)
	signer=$(signing_identity "Apple Distribution|3rd Party Mac Developer Application" -p codesigning)
	[ -n "$signer" ] || { echo "no valid Apple Distribution certificate of team $team_id in the keychain" >&2; exit 1; }
	installer=$(installer_identity)
	[ -n "$installer" ] || { echo "no valid Mac Installer Distribution certificate of team $team_id in the keychain" >&2; exit 1; }
	profile=$(provisioning_profile "$bundle" app-store) || {
		echo "no Mac App Store provisioning profile of team $team_id for $bundle: download it from the developer account into ~/Library/Developer/Xcode/UserData/Provisioning Profiles" >&2
		exit 1
	}
	package_name="native-note-v$version-appstore.pkg"
	[ ! -e "$repo/releases/$package_name" ] || { echo "$repo/releases/$package_name already exists: set a new version or build number in the project" >&2; exit 1; }

	lock_root
	build
	refuse_identifying_data
	universal
	sign "$universal_app" "$signer" "$profile" "$bundle" universal
	productbuild --component "$universal_app" /Applications --sign "$installer" "$root/out/$package_name" > /dev/null
	pkgutil --check-signature "$root/out/$package_name" | grep -q -F "$installer" || { echo "$package_name is not signed by $installer" >&2; exit 1; }

	mkdir -p "$repo/releases"
	cp "$root/out/$package_name" "$repo/releases/"
	(cd "$root/out" && shasum -a 256 -- "$package_name")
	echo "built $commit with Xcode $found into $repo/releases/$package_name; upload it with Transporter"
fi
