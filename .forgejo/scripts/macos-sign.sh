# shellcheck shell=bash disable=SC2154
readonly team_id=L3W5ZXTBAF
readonly repository_url=https://git.hloth.dev/hloth/native-note

project_setting() {
	git -C "$repo" show "$commit:clients/macos/native-note.xcodeproj/project.pbxproj" | awk -F ' = |;' '$1 ~ /^[[:space:]]*'"$1"'$/ && !found++ { print $2 }'
}

signing_identity() {
	local kinds="$1" policy=("${@:2}")
	security find-identity -v "${policy[@]}" | awk -v kinds="$kinds" -v team="$team_id" '
		match($0, /"[^"]+"$/) {
			name = substr($0, RSTART + 1, RLENGTH - 2)
			if (name ~ "^(" kinds "): .+ [(]" team "[)]$" && !found++) print $2
		}'
}

installer_identity() {
	security find-identity -v | awk -v team="$team_id" '
		match($0, /"[^"]+"$/) {
			name = substr($0, RSTART + 1, RLENGTH - 2)
			if (name ~ "^(3rd Party Mac Developer Installer|Mac Installer Distribution): .+ [(]" team "[)]$" && !found++) print name
		}'
}

provisioning_profile() {
	local bundle="$1" wanted="$2" profile kind
	for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
		[ -f "$profile" ] || continue
		security cms -D -i "$profile" > "$root.profile.plist" 2>/dev/null || continue
		field() { plutil -extract "$1" raw -o - "$root.profile.plist" 2>/dev/null; }
		kind="app-store"
		if [ "$(field ProvisionsAllDevices)" = true ]; then
			kind="developer-id"
		elif plutil -extract ProvisionedDevices xml1 -o /dev/null "$root.profile.plist" 2>/dev/null; then
			kind="development"
		fi
		if [ "$kind" = "$wanted" ] && [ "$(field TeamIdentifier.0)" = "$team_id" ] &&
			[ "$(field Entitlements.com\\.apple\\.application-identifier)" = "$team_id.$bundle" ] &&
			[[ "$(field ExpirationDate)" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
			rm "$root.profile.plist"
			echo "$profile"
			return
		fi
	done
	rm -f "$root.profile.plist"
	return 1
}

identity() {
	printf '%s\n' "$HOME" /Users/ "$(id -un)" "$(id -F)" "$(hostname)" "$(dirname "$(getconf DARWIN_USER_DIR)")" \
		"$(scutil --get ComputerName)" "$(scutil --get LocalHostName)" "$(dscl . -read "/Users/$(id -un)" GeneratedUID | cut -d ' ' -f 2)" \
		"$(git -C "$repo" config user.name)" "$(git -C "$repo" config user.email)" "$(git -C "$repo" config user.signingkey)"
	ioreg -rd1 -c IOPlatformExpertDevice | awk -F '"' '/"IOPlatform(UUID|SerialNumber)"/ { print $4 }'
}

refuse_identifying_data() {
	local arch leaks
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
}

sign() {
	local app="$1" signer="$2" profile="$3" bundle="$4" label="$5" entitlements entitlement
	entitlements="$root/entitlements-$label.plist"
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
		echo "the $label app still allows debuggers to attach (get-task-allow)" >&2
		exit 1
	fi
	for entitlement in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.files.user-selected.read-write; do
		[ "$(granted "${entitlement//./\\.}")" = true ] || { echo "the $label app lacks $entitlement" >&2; exit 1; }
	done
	[ "$(granted keychain-access-groups.0)" = "$team_id.$bundle" ] || { echo "the $label app lacks Touch ID's keychain group" >&2; exit 1; }
	[[ $(codesign -dv "$app" 2>&1) =~ flags=[^[:space:]]*runtime ]] || { echo "the $label app lacks the hardened runtime" >&2; exit 1; }
}
