#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: server-sign.sh <tag>}"
root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
key="$(git -C "$root" config user.signingkey)" || { echo "set git's user.signingkey to the GPG key that signs releases" >&2; exit 1; }
release="https://git.hloth.dev/hloth/native-note/releases/download/$tag"
work="$(mktemp -d)"
cleanup() {
	git -C "$root" worktree remove --force "$work/source" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

mkdir "$work/published"
curl -fsSL -o "$work/published/SHA256SUMS" "$release/SHA256SUMS"
while read -r _ name; do
	[[ "$name" =~ ^native-note-server-linux-[a-z0-9_]+$ ]] || { echo "SHA256SUMS lists an unexpected file: $name" >&2; exit 1; }
	curl -fsSL -o "$work/published/$name" "$release/$name"
done <"$work/published/SHA256SUMS"
(cd "$work/published" && sha256sum -c SHA256SUMS)

git -C "$root" worktree add --detach "$work/source" "$tag" >/dev/null
"$work/source/.forgejo/scripts/server-release.sh"
(cd "$work/source/releases" && sha256sum -c "$work/published/SHA256SUMS")

mkdir -p "$root/releases"
cp "$work/published/SHA256SUMS" "$root/releases/SHA256SUMS"
gpg --local-user "$key" --armor --detach-sign --output "$root/releases/SHA256SUMS.asc" "$root/releases/SHA256SUMS"
gpg --verify "$root/releases/SHA256SUMS.asc" "$root/releases/SHA256SUMS"
echo "reproduced every $tag binary; attach releases/SHA256SUMS.asc to the $tag release"
