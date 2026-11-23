#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly repo="$(git rev-parse --show-toplevel)"
readonly home="$HOME/Library/Developer/native-note-devtools/voiceover"
readonly app_id=dev.hloth.devtools.native-note-voiceover
readonly runner_id=dev.hloth.devtools.native-note-voiceover-run
readonly lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$home"

xcodebuild build -project "$repo/clients/macos/native-note.xcodeproj" -scheme native-note -configuration Release \
	-destination 'platform=macOS' -derivedDataPath "$home/build" \
	DEVELOPMENT_TEAM= NATIVE_NOTE_ENTITLEMENTS= CODE_SIGN_IDENTITY=- > "$home/build.log" 2>&1 ||
	{ echo "the app build failed, see $home/build.log" >&2; exit 1; }
built="$home/build/Build/Products/Release/Native Note.app"
"$lsregister" -u "$built" 2>/dev/null || true

app="$home/Native Note.app"
rm -rf "$app"
ditto "$built" "$app"
entitlements="$home/app.entitlements"
codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
plutil -replace CFBundleIdentifier -string "$app_id" "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$entitlements" "$app" >&2
"$lsregister" -u "$app" 2>/dev/null || true

cargo build --manifest-path "$repo/server/Cargo.toml" -p native-note-server --release >&2
cp -f "$repo/server/target/release/native-note-server" "$home/native-note-server"

swift build -c release --product voiceover-run >&2
runner="$home/Native Note VoiceOver Run.app"
rm -rf "$runner"
mkdir -p "$runner/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/voiceover-run" "$runner/Contents/MacOS/voiceover-run"
plutil -create xml1 "$runner/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "$runner_id" "$runner/Contents/Info.plist"
plutil -insert CFBundleExecutable -string voiceover-run "$runner/Contents/Info.plist"
plutil -insert CFBundleName -string "Native Note VoiceOver Run" "$runner/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$runner/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$runner/Contents/Info.plist"
plutil -insert NSAppleEventsUsageDescription -string "Drives VoiceOver through Native Note's common tasks." "$runner/Contents/Info.plist"
identity="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
codesign --force --sign "${identity:?no Apple Development identity in the keychain}" --options runtime \
	--entitlements VoiceOverRun.entitlements "$runner" >&2

echo "$runner"
