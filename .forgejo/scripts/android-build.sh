#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly java_major=21
readonly root=/tmp/native-note-android
readonly gradle_home=/tmp/native-note-android-gradle
readonly android_jar_sha256=d827b4304f0144ad6332f7a236ccf0659f6bd845f5ba739db475d9e822272c85
readonly r8_mapping_in_bundle=BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map
readonly kit=clients/macos/native-note-kit
readonly amalgamation=(Sources/SQLCipher/sqlite3.c Sources/SQLCipher/include/sqlite3.h)
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
readonly repo
commit=$(git -C "$repo" rev-parse --verify "${1:-HEAD}^{commit}")
epoch=$(git -C "$repo" log -1 --no-show-signature --format=%ct "$commit")
readonly commit epoch
: "${JAVA_HOME:?set JAVA_HOME to a JDK $java_major}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"

hermetic() {
	env -i PATH="$PATH" HOME="$HOME" GRADLE_USER_HOME="$gradle_home" JAVA_HOME="$JAVA_HOME" ANDROID_HOME="$ANDROID_HOME" \
		TZ=UTC LC_ALL=C SOURCE_DATE_EPOCH="$epoch" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"
}

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

found=$(hermetic "$JAVA_HOME/bin/java" -XshowSettings:properties -version 2>&1 | awk -F' = ' '/java.specification.version/ { print $2 }' || true)
readonly found
if [ "$found" != "$java_major" ]; then
	echo "JDK $java_major is required, $JAVA_HOME has ${found:-none}" >&2
	exit 1
fi

if ! echo "$android_jar_sha256  $ANDROID_HOME/platforms/android-37.1/android.jar" | sha256 -c - >/dev/null 2>&1; then
	echo "platform android-37.1 revision 1 is required in $ANDROID_HOME" >&2
	exit 1
fi

lock_root() {
	mkdir "$root.lock" 2>/dev/null || { echo "$root is in use by another android-build.sh, or remove $root.lock" >&2; exit 1; }
	trap 'rmdir "$root.lock"' EXIT
}

build() {
	local project=$root/src/clients/android version file
	rm -rf "$root"
	mkdir -m 700 "$root"
	mkdir "$root/src" "$root/out"
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$repo" -c core.autocrlf=false archive "$commit" | tar -x -C "$root/src"
	git -C "$repo" ls-tree -r "$commit" | while read -r _ type object path; do
		[ "$type" = commit ] || continue
		mkdir -p "$root/src/$path"
		GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$repo/$path" -c core.autocrlf=false archive "$object" | tar -x -C "$root/src/$path" ||
			{ echo "submodule $path lacks $object: run git submodule update --init $path" >&2; exit 1; }
	done

	"$repo/$kit/Scripts/sqlcipher-amalgamation.sh" >&2
	for file in "${amalgamation[@]}"; do
		cp "$repo/$kit/$file" "$root/src/$kit/$file"
	done

	(cd "$project" && hermetic ./gradlew --no-daemon --no-build-cache --dependency-verification=strict --console=plain assembleRelease bundleRelease) > "$root/build.log" 2>&1 ||
		{ echo "the build failed, see $root/build.log" >&2; exit 1; }

	version=$(sed -n 's/^[[:space:]]*versionName = "\(.*\)"$/\1/p' "$project/app/build.gradle.kts")
	cp "$project/app/build/outputs/apk/release/app-release-unsigned.apk" "$root/out/native-note-v$version-android-unsigned.apk"
	cp "$project/app/build/outputs/bundle/release/app-release.aab" "$root/out/native-note-v$version-android-unsigned.aab"
	hermetic zip -q -d "$root/out/native-note-v$version-android-unsigned.aab" "$r8_mapping_in_bundle"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	lock_root
	build
	echo "$commit" > "$root/commit"
	(cd "$root/out" && sha256 -- *)
	echo "built $commit with JDK $found into $root/out"
fi
