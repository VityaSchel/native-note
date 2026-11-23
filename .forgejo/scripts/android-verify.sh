#!/bin/bash
set -euo pipefail

readonly root=/tmp/native-note-android
readonly apksigner=${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools/36.0.0/apksigner
readonly pinned=$(cd "$(dirname "$0")/../.." && pwd -P)/clients/android/release-certificate.sha256
work=$(mktemp -d)
readonly work
trap 'rm -rf "${work:?}"' EXIT

[ $# -eq 1 ] || { echo "usage: android-verify.sh <published apk>, after android-build.sh <commit>" >&2; exit 2; }
readonly published=$1
[ -f "$root/commit" ] || { echo "no build in $root: run android-build.sh first" >&2; exit 1; }
rebuilt=$(find "$root/out" -name '*-android-unsigned.apk' | head -1)
[ -n "$rebuilt" ] || { echo "the build of $(cut -c 1-12 "$root/commit") has no unsigned APK" >&2; exit 1; }

perl -e '
	sub slurp { local $/; open my $in, "<:raw", $_[0] or die "$_[0]: $!\n"; <$in> }
	sub directory {
		my $eocd = rindex $_[0], "PK\x05\x06";
		die "no end of central directory\n" if $eocd < 0;
		($eocd, unpack "V", substr $_[0], $eocd + 16, 4);
	}
	my ($published, $rebuilt) = (slurp($ARGV[0]), slurp($ARGV[1]));
	my (undef, $signed) = directory($published);
	die "no APK signing block before the central directory\n" if substr($published, $signed - 16, 16) ne "APK Sig Block 42";
	my ($low, $high) = unpack "VV", substr $published, $signed - 24, 8;
	my $block = $signed - ($low + $high * 2**32) - 8;
	die "a malformed APK signing block\n" if $block < 0 || unpack("Q<", substr $published, $block, 8) != $low + $high * 2**32;
	my ($eocd, $entries) = directory($rebuilt);
	my $padding = $block - $entries;
	die "the signing block does not follow the rebuilt entries within a 4096-byte padding\n" if $padding < 0 || $padding >= 4096;
	my $grafted = substr($rebuilt, 0, $entries) . ("\0" x $padding) . substr($published, $block, $signed - $block) . substr($rebuilt, $entries);
	substr($grafted, $eocd + $signed - $entries + 16, 4) = pack "V", $signed;
	open my $out, ">:raw", $ARGV[2] or die "$ARGV[2]: $!\n";
	print $out $grafted;
' "$published" "$rebuilt" "$work/grafted.apk"

cmp -s "$work/grafted.apk" "$published" || { echo "✗ $(basename "$published") is not the build of $(cut -c 1-12 "$root/commit") with only a signature added" >&2; exit 1; }
"$apksigner" verify --min-sdk-version 31 "$published" || { echo "✗ $(basename "$published") has no valid signature" >&2; exit 1; }
digest=$("$apksigner" verify --print-certs "$published" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
if [ -f "$pinned" ] && [ "$digest" != "$(tr -d '[:space:]' <"$pinned")" ]; then
	echo "✗ $(basename "$published") is signed with $digest, not the pinned release certificate" >&2
	exit 1
fi
echo "✓ $(basename "$published") is the build of $(cut -c 1-12 "$root/commit") with only a signature added, by $digest"
