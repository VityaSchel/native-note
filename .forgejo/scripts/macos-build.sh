#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly xcode_build=27A266a
readonly architectures=(arm64 x86_64)
readonly root=/private/tmp/native-note-release
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
readonly repo
readonly developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
readonly kit=clients/macos/native-note-kit
readonly lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
readonly amalgamation=(Sources/SQLCipher/sqlite3.c Sources/SQLCipher/include/sqlite3.h)
commit=$(git -C "$repo" rev-parse --verify "${1:-HEAD}^{commit}")
epoch=$(git -C "$repo" log -1 --no-show-signature --format=%ct "$commit")
readonly commit epoch

hermetic() {
	env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="$developer_dir" TZ=UTC LC_ALL=C SOURCE_DATE_EPOCH="$epoch" \
		GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"
}

found=$(hermetic xcodebuild -version | awk '/Build version/ { print $3 }')
readonly found
if [ "$found" != "$xcode_build" ]; then
	echo "Xcode $xcode_build is required, found ${found:-none} at $developer_dir" >&2
	exit 1
fi

lock_root() {
	mkdir "$root.lock" 2>/dev/null || { echo "$root is in use by another macos-build.sh or macos-release.sh, or remove $root.lock" >&2; exit 1; }
	trap 'rmdir "$root.lock"' EXIT
}

app() { echo "$root/Native Note-$1.xcarchive/Products/Applications/Native Note.app"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$(app "$1")/Contents/Info.plist"; }
zip_of() { echo "$root/out/native-note-v$(plist "$1" CFBundleShortVersionString)-$1.zip"; }
package() {
	local app zip
	app=$(app "$1")
	zip=$(zip_of "$1")
	rm -f "$zip"
	chmod -R u=rwX,go=rX "$app"
	find "$app" -exec touch -h -d "$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)" {} +
	(cd "$(dirname "$app")" && find "Native Note.app" | LC_ALL=C sort | hermetic zip -q -X -y -9 -@ "$zip")
}

build() {
	local file sdk_build arch binary
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

	for arch in "${architectures[@]}"; do
		while IFS= read -r -d '' binary; do
			if file -b "$binary" | grep -q Mach-O && [ "$(lipo -archs "$binary")" != "$arch" ]; then
				echo "$binary holds $(lipo -archs "$binary"), not only $arch" >&2
				exit 1
			fi
		done < <(find "$(app "$arch")/Contents" -type f -perm -u+x -print0)
		package "$arch"
	done
	find "$root" -type d -name "Native Note.app" -prune -exec "$lsregister" -u {} \; 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	lock_root
	build
	echo "$commit" > "$root/commit"
	(cd "$root/out" && shasum -a 256 -- *.zip)
	echo "built $commit with Xcode $found into $root/out"
fi
