#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/op13-baseline-build.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

[[ -f "$script" ]] || fail "expected baseline harness at $script"

# shellcheck source=/dev/null
source "$script"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/op13-baseline-test.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
source_dir="$tmpdir/source"

mkdir -p "$source_dir"
git -C "$source_dir" init --quiet
git -C "$source_dir" config user.name "OP13 baseline test"
git -C "$source_dir" config user.email "op13-baseline-test@example.invalid"

printf 'VERSION = 6\nPATCHLEVEL = 6\nSUBLEVEL = 118\n' >"$source_dir/Makefile"

git -C "$source_dir" add Makefile
git -C "$source_dir" commit --quiet -m "kernel 6.6.118"
expected_commit=$(git -C "$source_dir" rev-parse HEAD)

verify_source "$source_dir" "$expected_commit" "6.6.118"

sed -i 's/SUBLEVEL = 118/SUBLEVEL = 117/' "$source_dir/Makefile"
expect_failure verify_source "$source_dir" "$expected_commit" "6.6.118"

sed -i 's/SUBLEVEL = 117/SUBLEVEL = 118/' "$source_dir/Makefile"
git -C "$source_dir" add Makefile
git -C "$source_dir" commit --quiet --allow-empty -m "different revision"
expect_failure verify_source "$source_dir" "$expected_commit" "6.6.118"

printf 'PASS: OP13 baseline source guard\n'
