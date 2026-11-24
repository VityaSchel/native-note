#!/bin/bash
set -euo pipefail

readonly out=${1:?usage: build-speech.sh <apk to write>}
readonly sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
readonly tools=$sdk/build-tools/36.0.0
readonly platform=$sdk/platforms/android-37.1/android.jar
readonly here=$(cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

"${JAVA_HOME:?set JAVA_HOME to a JDK 21}/bin/javac" -nowarn --release 17 -cp "$platform" -d "$work/classes" "$here/speech/SpeechLog.java"
"$tools/d8" --min-api 31 --lib "$platform" --output "$work" "$work"/classes/dev/hloth/devtools/speech/*.class
"$tools/aapt2" link --manifest "$here/speech/AndroidManifest.xml" -I "$platform" --min-sdk-version 31 --target-sdk-version 36 -o "$work/unsigned.apk"
(cd "$work" && zip -q unsigned.apk classes.dex)
"$tools/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
"$tools/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --v4-signing-enabled false --out "$out" "$work/aligned.apk"
