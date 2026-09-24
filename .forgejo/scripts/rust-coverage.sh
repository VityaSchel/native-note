#!/usr/bin/env bash
set -euo pipefail

cd -P "$(dirname "$0")/../../spec/generator"
root="$(pwd -P)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export RUSTFLAGS="-C instrument-coverage"
export LLVM_PROFILE_FILE="$work/profiles/%p-%m.profraw"
export CARGO_TARGET_DIR="$work/target"

binaries="$(cargo test --locked --no-run --message-format=json | grep -oE '"executable":"[^"]+"' | cut -d'"' -f4)"
objects=()
while IFS= read -r binary; do
	objects+=(-object "$binary")
done <<<"$binaries"
cargo test --locked

sources=()
while IFS= read -r source; do
	sources+=("$source")
done < <(find "$root/src" -name '*.rs' -not -path "$root/src/bin/*" | sort)

tools="$(rustc --print sysroot)/lib/rustlib/$(rustc --print host-tuple)/bin"
"$tools/llvm-profdata" merge -sparse -o "$work/tests.profdata" "$work"/profiles/*.profraw
"$tools/llvm-cov" export -format=lcov -instr-profile="$work/tests.profdata" "${objects[@]}" \
	-sources "${sources[@]}" >"$work/lcov.info"

awk -F'[:,]' -v root="$root/" '
	/^SF:/ {
		file = substr($0, 4)
		if (index(file, root) != 1) {
			foreign = foreign "\n  " file
			file = ""
			next
		}
		file = substr(file, length(root) + 1)
		files[++count] = file
	}
	/^DA:/ && file != "" {
		lines[file]++
		if ($3 == 0) {
			missed[file]++
			uncovered = uncovered "\n  spec/generator/" file ":" $2
		}
	}
	END {
		printf "%-28s %6s %7s\n", "file", "lines", "missed"
		for (i = 1; i <= count; i++) {
			f = files[i]
			printf "%-28s %6d %7d\n", f, lines[f], missed[f]
			total += lines[f]
			total_missed += missed[f]
		}
		printf "%-28s %6d %7d\n", "total", total, total_missed
		if (foreign != "") {
			print "::error::coverage report included files outside spec/generator:" foreign
			exit 1
		}
		if (total == 0) {
			print "::error::no coverage data for spec/generator/src"
			exit 1
		}
		if (total_missed > 0) {
			print "::error::" total_missed " line(s) in spec/generator/src never run under test:" uncovered
			exit 1
		}
	}
' "$work/lcov.info"
