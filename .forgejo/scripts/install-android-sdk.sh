#!/usr/bin/env bash
set -euo pipefail

sdk="${1:?usage: install-android-sdk.sh <sdk directory>}"
readonly cmdline_tools=commandlinetools-linux-13114758_latest.zip
readonly cmdline_tools_sha256=7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee
readonly packages=("platforms;android-37.1" "build-tools;36.0.0" "ndk;30.0.16248370" "cmake;4.1.2")

if [ "$(uname -s)" != Linux ]; then
	echo "this installs the Linux SDK; on macOS use Android Studio's SDK Manager" >&2
	exit 1
fi

java_home="/usr/lib/jvm/java-21-openjdk-$(dpkg --print-architecture)"
{ command -v curl && command -v unzip && command -v zip && command -v git && command -v cc && command -v make && [ -x "$java_home/bin/javac" ]; } >/dev/null 2>&1 || {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -y
	apt-get install -y --no-install-recommends ca-certificates curl unzip zip git gcc libc6-dev make openjdk-21-jdk-headless
}

sdkmanager="$sdk/cmdline-tools/19.0/bin/sdkmanager"
if [ ! -x "$sdkmanager" ]; then
	mkdir -p "$sdk/cmdline-tools"
	workdir="$(mktemp -d "$sdk/cmdline-tools/.download.XXXXXX")"
	trap 'rm -rf "$workdir"' EXIT
	curl -fsSLo "$workdir/$cmdline_tools" "https://dl.google.com/android/repository/$cmdline_tools"
	echo "$cmdline_tools_sha256  $workdir/$cmdline_tools" | sha256sum -c -
	unzip -q "$workdir/$cmdline_tools" -d "$workdir"
	rm -rf "${sdk:?}/cmdline-tools/19.0"
	mv "$workdir/cmdline-tools" "$sdk/cmdline-tools/19.0"
fi

export JAVA_HOME="$java_home"
"$sdkmanager" --sdk_root="$sdk" --licenses < <(yes) > /dev/null
"$sdkmanager" --sdk_root="$sdk" --install "${packages[@]}" > /dev/null
