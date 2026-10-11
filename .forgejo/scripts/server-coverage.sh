#!/usr/bin/env bash
set -euo pipefail

nightly="nightly-2026-09-27"
package="native-note-core"

cd -P "$(dirname "$0")/../../server"
root="$(pwd -P)/$package/src"

rustup toolchain install "$nightly" --profile minimal --component llvm-tools-preview --no-self-update

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export RUSTFLAGS="-C instrument-coverage -Zcoverage-options=branch"
export LLVM_PROFILE_FILE="$work/profiles/%p-%m.profraw"
export CARGO_TARGET_DIR="$work/target"

binaries="$(cargo "+$nightly" test --locked -p "$package" --no-run --message-format=json | grep -oE '"executable":"[^"]+"' | cut -d'"' -f4)"
objects=()
while IFS= read -r binary; do
	objects+=(-object "$binary")
done <<<"$binaries"
cargo "+$nightly" test --locked -p "$package" -- --skip props

sources=()
while IFS= read -r source; do
	sources+=("$source")
done < <(find "$root" -name '*.rs' -not -name tests.rs | sort)

tools="$(rustc "+$nightly" --print sysroot)/lib/rustlib/$(rustc "+$nightly" --print host-tuple)/bin"
"$tools/llvm-profdata" merge -sparse -o "$work/tests.profdata" "$work"/profiles/*.profraw
coverage=(-instr-profile="$work/tests.profdata" "${objects[@]}")

# llvm-cov report TOTAL, lcov LH/LF/BRH/BRF and the JSON summary take the maximum over copies of a function instead of the union, so only per-record data is read.
"$tools/llvm-cov" export -format=lcov "${coverage[@]}" -sources "${sources[@]}" >"$work/lcov.info"
while IFS= read -r source; do
	echo "SF:$source"
	"$tools/llvm-cov" export -format=text -skip-functions "${coverage[@]}" -sources "$source" \
		| { grep -oE '\[[0-9]+,[0-9]+,[0-9]+,true,true,false\]' || true; } \
		| sed -E 's/^\[([0-9]+),([0-9]+),([0-9]+),.*/RG:\1,\2,\3/'
done < <(sed -n 's/^SF://p' "$work/lcov.info") >"$work/regions.info"

status=0
awk -F'[:,]' -v root="$root/" -v shown="$work/shown" -v prefix="server/$package/src/" '
	/^SF:/ {
		path = substr($0, 4)
		if (index(path, root) != 1) {
			foreign = foreign "\n  " path
			file = ""
			next
		}
		file = substr(path, length(root) + 1)
		if (!(file in paths)) {
			paths[file] = path
			files[++count] = file
		}
	}
	/^DA:/ && file != "" {
		lines[file]++
		if ($3 == 0) {
			missed_lines[file]++
			uncovered_lines = uncovered_lines "\n  " prefix file ":" $2
		}
	}
	/^BRDA:/ && file != "" {
		branches[file]++
		if ($5 == 0 || $5 == "-") {
			missed_branches[file]++
			uncovered_branches = uncovered_branches "\n  " prefix file ":" $2 " (condition " ($3 + 1) ", " ($4 % 2 == 0 ? "true" : "false") ")"
		}
	}
	/^RG:/ && file != "" {
		regions[file]++
		if ($4 == 0) {
			missed_regions[file]++
			uncovered_regions = uncovered_regions "\n  " prefix file ":" $2 ":" $3
		}
	}
	END {
		printf "%-16s %6s %7s %9s %7s %8s %7s\n", "file", "lines", "missed", "branches", "missed", "regions", "missed"
		for (i = 1; i <= count; i++) {
			f = files[i]
			printf "%-16s %6d %7d %9d %7d %8d %7d\n", f, lines[f], missed_lines[f], branches[f], missed_branches[f], regions[f], missed_regions[f]
			total_branches += branches[f]
			total_missed += missed_lines[f] + missed_branches[f] + missed_regions[f]
			if (lines[f] == 0 || regions[f] == 0) {
				empty = empty "\n  " prefix f
			}
			if (missed_lines[f] + missed_branches[f] + missed_regions[f] > 0) {
				print paths[f] > shown
			}
		}
		if (foreign != "") {
			print "::error::coverage report included files outside " prefix ":" foreign
			exit 1
		}
		if (count == 0) {
			print "::error::no coverage data for " prefix
			exit 1
		}
		if (total_branches == 0) {
			print "::error::no branch coverage data for " prefix
			exit 1
		}
		if (empty != "") {
			print "::error::files in " prefix " with no line or region data:" empty
			exit 1
		}
		if (uncovered_lines != "") {
			print "::error::lines in " prefix " never run by a deterministic test:" uncovered_lines
		}
		if (uncovered_branches != "") {
			print "::error::branches in " prefix " never taken by a deterministic test:" uncovered_branches
		}
		if (uncovered_regions != "") {
			print "::error::regions in " prefix " never run by a deterministic test:" uncovered_regions
		}
		if (total_missed > 0) {
			exit 1
		}
	}
' "$work/lcov.info" "$work/regions.info" || status=$?

if [ "$status" -ne 0 ] && [ -s "$work/shown" ]; then
	shown=()
	while IFS= read -r source; do
		shown+=("$source")
	done <"$work/shown"
	"$tools/llvm-cov" show -show-branches=count -show-regions "${coverage[@]}" -sources "${shown[@]}"
fi
exit "$status"
