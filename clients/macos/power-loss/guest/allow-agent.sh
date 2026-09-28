#!/bin/sh
set -eu

[ "$#" -eq 3 ] || { echo "usage: allow-agent.sh <account> <launcher> <sudoers file>" >&2; exit 2; }
account=$1
launcher=$2
rule=$3

draft=$(mktemp "$rule.XXXXXX")
trap 'rm -f "$draft"' EXIT
printf '%s ALL=(root) NOPASSWD: %s --stdio\n' "$account" "$launcher" >"$draft"
chmod 0440 "$draft"
visudo -cf "$draft" >/dev/null
mv -f "$draft" "$rule"
