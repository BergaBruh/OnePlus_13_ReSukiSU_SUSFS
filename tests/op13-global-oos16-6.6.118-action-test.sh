#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/configs/oos16/OP13-GLOBAL-6.6.118.json"
manifest="$repo_root/manifests/oos16/oneplus_13_global_6.6.118_w.xml"
workflow="$repo_root/.github/workflows/build-op13-global-oos16-6.6.118.yml"
build_action="$repo_root/.github/actions/build-kernel/action.yml"
source_sync_action="$repo_root/.github/actions/kernel-source-sync/action.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$config" ]] || fail "missing OP13 Global config"
[[ -f "$manifest" ]] || fail "missing OP13 Global manifest"
[[ -f "$workflow" ]] || fail "missing OP13 Global workflow"

python3 - "$config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    config = json.load(fh)

expected = {
    "model": "OP13",
    "manifest": "oneplus_13_global_6.6.118_w.xml",
    "android_version": "android15",
    "kernel_version": "6.6",
    "os_version": "OOS16",
    "susfs": True,
    "custom_patches": False,
    "hmbird": False,
    "bbg": False,
    "bbr": False,
    "bbr3": False,
    "ttl": False,
    "ip_set": False,
    "unicode": False,
    "ntsync": False,
}
for key, value in expected.items():
    if config.get(key) != value:
        raise SystemExit(f"{key}: expected {value!r}, got {config.get(key)!r}")
PY

for pin in \
  e1b346b6b4f4096eb342ae3684838a942fd6f6c4 \
  d50b305f7da9e14715a25120a4ac7b1a4b8b97c3 \
  ea531d03965f702a45e1b0ab7c5db8d196c975c3; do
  grep -q "$pin" "$manifest" || fail "manifest is missing pin $pin"
done

grep -q '^  workflow_dispatch:' "$workflow" || fail "workflow must be manual-only"
! grep -q 'schedule:\|push:\|pull_request:' "$workflow" || fail "workflow has an automatic trigger"
grep -q '^  contents: write$' "$workflow" || fail "workflow needs release-cache write permission"
grep -q 'OP13-GLOBAL-6.6.118.json' "$workflow" || fail "workflow does not use its dedicated config"
grep -q 'ReSukiSU' "$workflow" || fail "workflow does not select ReSukiSU"
grep -q 'b0b73beb24341b7029a866005e9578ab58aa2df7' "$workflow" || fail "workflow is missing ReSukiSU pin"
grep -q '069baca65e58557019dbf906e802f518428c5a84' "$workflow" || fail "workflow is missing SUSFS pin"
! grep -q 'matrix:' "$workflow" || fail "workflow must not build a model matrix"

grep -q 'ReSukiSU/ReSukiSU/\$RESUKISU_SETUP_REF/kernel/setup.sh' "$build_action" ||
  fail "ReSukiSU setup script must use the requested pinned ref"

grep -q 'cache miss; downloading directly' "$source_sync_action" ||
  fail "source sync must fall back to direct pinned archives when its cache is cold"

custom_patch_guards=$(grep -c "env.OP_CUSTOM_PATCHES == 'true'" "$build_action" || true)
[[ "$custom_patch_guards" -ge 5 ]] ||
  fail "optional WildKernels patches must be guarded for the OP13-only workflow"

grep -q 'CONFIG_FAKE_DISABLE="${CONFIG_FAKE_DISABLE:-}"' "$build_action" ||
  fail "build must initialise the optional fake-config exclusion list"

printf 'PASS: OP13 Global OOS16 6.6.118 action contract\n'
