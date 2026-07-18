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

missing_command="definitely-missing-op13-baseline-command"
if preflight_output=$(preflight_commands git "$missing_command" 2>&1); then
  fail "expected preflight to reject a missing command"
fi
[[ "$preflight_output" == *"$missing_command"* ]] ||
  fail "preflight did not name the missing command"

toolchain_dir="$tmpdir/toolchain"
mkdir -p "$toolchain_dir/clang-r510928/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$toolchain_dir/clang-r510928/bin/clang"
chmod +x "$toolchain_dir/clang-r510928/bin/clang"
verify_toolchain "$toolchain_dir" "r510928"
rm "$toolchain_dir/clang-r510928/bin/clang"
expect_failure verify_toolchain "$toolchain_dir" "r510928"

modules_dir="$tmpdir/modules"
mkdir -p "$modules_dir/vendor/oplus/kernel/touchpanel/kernelFwUpdate"
git -C "$modules_dir" init --quiet
git -C "$modules_dir" config user.name "OP13 baseline test"
git -C "$modules_dir" config user.email "op13-baseline-test@example.invalid"
printf 'config OPLUS_FEATURE_TEST\n' >"$modules_dir/vendor/oplus/kernel/touchpanel/kernelFwUpdate/Kconfig"
git -C "$modules_dir" add vendor
git -C "$modules_dir" commit --quiet -m "matching modules"
expected_modules_commit=$(git -C "$modules_dir" rev-parse HEAD)

verify_modules "$modules_dir" "$expected_modules_commit"
rm "$modules_dir/vendor/oplus/kernel/touchpanel/kernelFwUpdate/Kconfig"
expect_failure verify_modules "$modules_dir" "$expected_modules_commit"

build_workspace="$tmpdir/empty-build-workspace"
if build_output=$(OP13_BASELINE_WORKDIR="$build_workspace" bash "$script" build 2>&1); then
  fail "expected build to reject an unverified source"
fi
[[ "$build_output" == *"source directory is not a Git checkout"* ]] ||
  fail "build did not stop at the source guard"

printf 'PASS: OP13 baseline source guard\n'
