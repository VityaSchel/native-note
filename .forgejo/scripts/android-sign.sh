#!/bin/bash
set -euo pipefail

readonly usage="usage: ANDROID_KEYSTORE=<release keystore> ANDROID_UPLOAD_KEYSTORE=<Play upload keystore> android-sign.sh <unsigned apk> <unsigned aab> <output directory>"
readonly apk=${1:?$usage}
readonly aab=${2:?$usage}
readonly out=${3:?$usage}
readonly keystore=${ANDROID_KEYSTORE:?$usage}
readonly upload_keystore=${ANDROID_UPLOAD_KEYSTORE:?$usage}
readonly apksigner=${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools/36.0.0/apksigner
readonly jarsigner=${JAVA_HOME:+$JAVA_HOME/bin/}jarsigner
readonly pinned=$(cd "$(dirname "$0")/../.." && pwd -P)/clients/android/release-certificate.sha256
readonly signed_apk=$out/$(basename "${apk/-unsigned/}")
readonly signed_aab=$out/$(basename "${aab/-unsigned/-play}")

[ -f "$pinned" ] || { echo "no pinned release certificate: write the release key's certificate SHA-256 to clients/android/release-certificate.sha256" >&2; exit 1; }
mkdir -p "$out"

"$apksigner" sign --ks "$keystore" --ks-type PKCS12 --ks-key-alias native-note \
	--alignment-preserved --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
	--out "$signed_apk" "$apk"
digest=$("$apksigner" verify --min-sdk-version 31 --print-certs "$signed_apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
if [ "$digest" != "$(tr -d '[:space:]' <"$pinned")" ]; then
	rm -f "$signed_apk"
	echo "the keystore's certificate $digest is not the pinned release certificate" >&2
	exit 1
fi

"$jarsigner" -keystore "$upload_keystore" -storetype PKCS12 -sigalg SHA256withRSA -digestalg SHA-256 \
	-signedjar "$signed_aab" "$aab" native-note-upload > /dev/null
"$jarsigner" -verify "$signed_aab" | grep -q '^jar verified\.$' || { rm -f "$signed_aab"; echo "the signed AAB does not verify" >&2; exit 1; }

echo "signed $(basename "$signed_apk") with the release key and $(basename "$signed_aab") with the Play upload key"
