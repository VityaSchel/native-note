#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly xcode_build=27A266a
readonly team_id=L3W5ZXTBAF
readonly notary_profile=native-note
readonly repository_url=https://git.hloth.dev/hloth/native-note
readonly architectures=(arm64 x86_64)
readonly root=/private/tmp/native-note-release
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
readonly repo
readonly developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
readonly kit=clients/macos/native-note-kit
readonly amalgamation=(Sources/SQLCipher/sqlite3.c Sources/SQLCipher/include/sqlite3.h)
rebuild=
if [ "${1:-}" = --rebuild ]; then
	rebuild=1
	shift
fi
readonly rev=${1:-HEAD}

if [ -z "$rebuild" ] && [ -n "$(git -C "$repo" status --porcelain)" ]; then
	echo "commit or stash your changes first" >&2
	exit 1
fi
commit=$(git -C "$repo" rev-parse --verify "$rev^{commit}")
epoch=$(git -C "$repo" log -1 --no-show-signature --format=%ct "$commit")

hermetic() {
	env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="$developer_dir" TZ=UTC LC_ALL=C SOURCE_DATE_EPOCH="$epoch" \
		GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"
}

found=$(hermetic xcodebuild -version | awk '/Build version/ { print $3 }')
if [ "$found" != "$xcode_build" ]; then
	echo "Xcode $xcode_build is required, found ${found:-none} at $developer_dir" >&2
	exit 1
fi

project_setting() {
	git -C "$repo" show "$commit:clients/macos/native-note.xcodeproj/project.pbxproj" | awk -F ' = |;' '$1 ~ /^[[:space:]]*'"$1"'$/ && !found++ { print $2 }'
}

developer_id_profile() {
	local profile
	for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile; do
		[ -f "$profile" ] || continue
		security cms -D -i "$profile" > "$root.profile.plist" 2>/dev/null || continue
		field() { plutil -extract "$1" raw -o - "$root.profile.plist" 2>/dev/null; }
		if [ "$(field ProvisionsAllDevices)" = true ] && [ "$(field TeamIdentifier.0)" = "$team_id" ] &&
			[ "$(field Entitlements.com\\.apple\\.application-identifier)" = "$team_id.$1" ] &&
			[[ "$(field ExpirationDate)" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
			rm "$root.profile.plist"
			echo "$profile"
			return
		fi
	done
	rm -f "$root.profile.plist"
	return 1
}

signer=
profile=
bundle=
if [ -z "$rebuild" ] && [ -n "$team_id" ]; then
	bundle=$(project_setting PRODUCT_BUNDLE_IDENTIFIER)
	signer=$(security find-identity -v -p codesigning | awk '/"Developer ID Application: .+ \('"$team_id"'\)"$/ && !found++ { print $2 }') || true
	if [ -z "$signer" ]; then
		echo "no valid Developer ID Application certificate of team $team_id in the keychain" >&2
		exit 1
	fi
	profile=$(developer_id_profile "$bundle") || {
		echo "no Developer ID provisioning profile of team $team_id for $bundle: download it from the developer account into ~/Library/Developer/Xcode/UserData/Provisioning Profiles" >&2
		exit 1
	}
fi

if [ -z "$rebuild" ]; then
	version=$(project_setting MARKETING_VERSION)
	for arch in "${architectures[@]}"; do
		if [ -e "$repo/releases/Native-Note-$version-$arch.zip" ]; then
			echo "$repo/releases/Native-Note-$version-$arch.zip already exists: set a new version in the project" >&2
			exit 1
		fi
	done
fi

mkdir "$root.lock" 2>/dev/null || { echo "$root is in use by another macos-release.sh or macos-verify.sh, or remove $root.lock" >&2; exit 1; }
trap 'rmdir "$root.lock"' EXIT
rm -rf "$root"
mkdir -m 700 "$root"
mkdir "$root/src" "$root/out"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$repo" -c core.autocrlf=false archive "$commit" | tar -x -C "$root/src"

"$repo/$kit/Scripts/sqlcipher-amalgamation.sh" >&2
for file in "${amalgamation[@]}"; do
	cp "$repo/$kit/$file" "$root/src/$kit/$file"
done
hermetic "$root/src/$kit/Scripts/sqlcipher-amalgamation.sh" > /dev/null 2>&1 || {
	echo "the SQLCipher amalgamation in $repo is not the one $commit pins: check out $commit and run git submodule update" >&2
	exit 1
}

sdk_build=$(hermetic xcrun --sdk macosx --show-sdk-build-version)
for arch in "${architectures[@]}"; do
	hermetic xcodebuild -project "$root/src/clients/macos/native-note.xcodeproj" -scheme native-note -configuration Release \
		-destination generic/platform=macOS -derivedDataPath "$root/build-$arch" -clonedSourcePackagesDirPath "$root/packages" \
		-onlyUsePackageVersionsFromResolvedFile -archivePath "$root/Native Note-$arch.xcarchive" \
		ARCHS="$arch" ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM= NATIVE_NOTE_ENTITLEMENTS= CODE_SIGN_IDENTITY=- \
		MAC_OS_X_PRODUCT_BUILD_VERSION="$sdk_build" archive > "$root/build-$arch.log" 2>&1 ||
		{ echo "the $arch build failed, see $root/build-$arch.log" >&2; exit 1; }
done

app() { echo "$root/Native Note-$1.xcarchive/Products/Applications/Native Note.app"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$(app "$1")/Contents/Info.plist"; }
zip_of() { echo "$root/out/Native-Note-$(plist "$1" CFBundleShortVersionString)-$1.zip"; }
package() {
	local app zip
	app=$(app "$1")
	zip=$(zip_of "$1")
	rm -f "$zip"
	chmod -R u=rwX,go=rX "$app"
	find "$app" -exec touch -h -d "$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)" {} +
	(cd "$(dirname "$app")" && find "Native Note.app" | LC_ALL=C sort | hermetic zip -q -X -y -9 -@ "$zip")
}

for arch in "${architectures[@]}"; do
	while IFS= read -r -d '' binary; do
		if file -b "$binary" | grep -q Mach-O && [ "$(lipo -archs "$binary")" != "$arch" ]; then
			echo "$binary holds $(lipo -archs "$binary"), not only $arch" >&2
			exit 1
		fi
	done < <(find "$(app "$arch")/Contents" -type f -perm -u+x -print0)
	package "$arch"
done

identity() {
	printf '%s\n' "$HOME" /Users/ "$(id -un)" "$(id -F)" "$(hostname)" "$(dirname "$(getconf DARWIN_USER_DIR)")" \
		"$(scutil --get ComputerName)" "$(scutil --get LocalHostName)" "$(dscl . -read "/Users/$(id -un)" GeneratedUID | cut -d ' ' -f 2)" \
		"$(git -C "$repo" config user.name)" "$(git -C "$repo" config user.email)" "$(git -C "$repo" config user.signingkey)"
	ioreg -rd1 -c IOPlatformExpertDevice | awk -F '"' '/"IOPlatform(UUID|SerialNumber)"/ { print $4 }'
}
if [ -z "$rebuild" ]; then
	for arch in "${architectures[@]}"; do
		leaks=$({ cat "$(zip_of "$arch")"; find "$(app "$arch")" -type f -exec cat {} +; find "$root/src" -type f -path '*.icon/*' -exec cat {} +; } |
			bundle=$(plist "$arch" CFBundleIdentifier) repository=$repository_url copyright=$(plist "$arch" NSHumanReadableCopyright) \
				perl -0777 -pe 's/\Q$ENV{bundle}\E|\Q$ENV{repository}\E|\Q$ENV{copyright}\E//g' |
			LC_ALL=C grep -a -o -i -F -f <(identity 2>/dev/null | grep -v '^$') | sort -u | paste -s -d , -) || true
		if [ -n "$leaks" ]; then
			rm "$root/out/"*.zip
			echo "the $arch release contains identifying data: $leaks" >&2
			exit 1
		fi
	done
fi

sign() {
	local app entitlements entitlement
	app=$(app "$1")
	entitlements="$root/entitlements-$1.plist"
	codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
	plutil -insert com\\.apple\\.application-identifier -string "$team_id.$bundle" "$entitlements"
	plutil -insert com\\.apple\\.developer\\.team-identifier -string "$team_id" "$entitlements"
	plutil -insert keychain-access-groups -json "[\"$team_id.$bundle\"]" "$entitlements"
	cp "$profile" "$app/Contents/embedded.provisionprofile"
	codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$signer" "$app"
	codesign --verify --strict --deep "$app"
	codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
	granted() { plutil -extract "$1" raw -o - "$entitlements" 2>/dev/null; }
	if granted com\\.apple\\.security\\.get-task-allow > /dev/null; then
		echo "the $1 app still allows debuggers to attach (get-task-allow)" >&2
		exit 1
	fi
	for entitlement in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.files.user-selected.read-write; do
		[ "$(granted "${entitlement//./\\.}")" = true ] || { echo "the $1 app lacks $entitlement" >&2; exit 1; }
	done
	[ "$(granted keychain-access-groups.0)" = "$team_id.$bundle" ] || { echo "the $1 app lacks Touch ID's keychain group" >&2; exit 1; }
	[[ $(codesign -dv "$app" 2>&1) =~ flags=[^[:space:]]*runtime ]] || { echo "the $1 app lacks the hardened runtime" >&2; exit 1; }
}

if [ -n "$signer" ]; then
	for arch in "${architectures[@]}"; do
		rm "$(zip_of "$arch")"
		sign "$arch"
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
fi

if [ -z "$rebuild" ]; then
	mkdir -p "$repo/releases"
	cp "$root/out/"*.zip "$repo/releases/"
fi
(cd "$root/out" && shasum -a 256 -- *.zip)
echo "built $commit with Xcode $found into $root/out"
