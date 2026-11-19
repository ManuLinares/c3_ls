#!/bin/sh
# Run the stdlib sweep (test/stdlib_sweep_test.c3), one process per file.
# Usage: test/sweep.sh OUT.tsv [std-subdir]
set -eu
out=$(realpath -m "$1")
sub=${2:-}
std=$(c3c compile --build-env | sed -n 's/^Stdlib *: *//p')
parts=$(mktemp -d)
trap 'rm -rf "$parts"' EXIT
log=$(c3c test -O1 --warn-builtin=no --suppress-run 2>&1) || { echo "$log" >&2; exit 1; }
(cd "$std/std" && find "./$sub" -name '*.c3' | sed 's|^\./||; s|^/||') |
	xargs -P "$(nproc)" -I{} sh -c 'SWEEP_DIR="$1" SWEEP_OUT="$2/$(echo "$1" | tr / _).tsv" timeout 300 ./build/testrun --test-filter stdlib_sweep --test-noleak >/dev/null 2>&1 || echo "failed: $1" >&2' _ {} "$parts"
cat "$parts"/*.tsv > "$out"
cut -f1 "$out" | sort | uniq -c
