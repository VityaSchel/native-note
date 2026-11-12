#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: DEVELOPMENT_TEAM=<team ID> NOTARY_PROFILE=<notarytool keychain profile> macos-release.sh <version>}"
team="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the team that holds the Developer ID certificate}"
notary="${NOTARY_PROFILE:?set NOTARY_PROFILE to a profile stored with xcrun notarytool store-credentials}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
one_app_per_architecture=(arm64 x86_64)

root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
	echo "commit or stash every change first: a release is built from a commit only" >&2
	exit 1
fi
"$root/clients/macos/native-note-kit/Scripts/sqlcipher-amalgamation.sh"
out="$root/releases"
for arch in "${one_app_per_architecture[@]}"; do
	if [[ -e "$out/Native-Note-$version-$arch.zip" ]]; then
		echo "$out/Native-Note-$version-$arch.zip already exists" >&2
		exit 1
	fi
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
build="$(git -C "$root" rev-list --count HEAD)"

plutil -create xml1 "$work/export.plist"
plutil -insert method -string developer-id "$work/export.plist"
plutil -insert teamID -string "$team" "$work/export.plist"
plutil -insert signingStyle -string automatic "$work/export.plist"

release() {
	local arch="$1"
	local stage="$work/$arch"
	local app="$stage/export/Native Note.app"
	local zip="$out/Native-Note-$version-$arch.zip"

	cd "$root/clients/macos"
	xcodebuild archive -project native-note.xcodeproj -scheme native-note -configuration Release \
		-destination 'generic/platform=macOS' -archivePath "$stage/Native Note.xcarchive" -derivedDataPath "$stage/derived" \
		-allowProvisioningUpdates DEVELOPMENT_TEAM="$team" NATIVE_NOTE_ENTITLEMENTS=NativeNote.entitlements \
		ARCHS="$arch" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build"
	xcodebuild -exportArchive -archivePath "$stage/Native Note.xcarchive" -exportPath "$stage/export" \
		-exportOptionsPlist "$work/export.plist" -allowProvisioningUpdates

	codesign --verify --strict --deep "$app"
	while IFS= read -r -d '' binary; do
		if file -b "$binary" | grep -q "Mach-O" && [[ "$(lipo -archs "$binary")" != "$arch" ]]; then
			echo "$binary holds $(lipo -archs "$binary"), not only $arch" >&2
			exit 1
		fi
	done < <(find "$app/Contents" -type f -perm -u+x -print0)
	codesign -d --entitlements - --xml "$app" >"$stage/entitlements.plist" 2>/dev/null
	entitlement() {
		/usr/libexec/PlistBuddy -c "Print :$1" "$stage/entitlements.plist" 2>/dev/null
	}
	if entitlement com.apple.security.get-task-allow >/dev/null; then
		echo "the export still allows debuggers to attach (get-task-allow)" >&2
		exit 1
	fi
	for granted in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.files.user-selected.read-write; do
		[[ "$(entitlement "$granted")" == true ]] || { echo "the export lacks $granted" >&2; exit 1; }
	done
	[[ "$(entitlement keychain-access-groups:0)" == "$team.dev.hloth.nativenote" ]] || { echo "the export lacks Touch ID's keychain group" >&2; exit 1; }
	[[ "$(codesign -d --verbose=2 "$app" 2>&1)" == *"(runtime)"* ]] || { echo "the export lacks the hardened runtime" >&2; exit 1; }

	ditto -c -k --keepParent "$app" "$stage/notarize.zip"
	xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$notary" --wait
	xcrun stapler staple "$app"
	spctl --assess --type execute --verbose=2 "$app"

	mkdir -p "$out"
	ditto -c -k --keepParent "$app" "$zip"
	(cd "$out" && shasum -a 256 "$(basename "$zip")")
}

for arch in "${one_app_per_architecture[@]}"; do
	release "$arch"
done
