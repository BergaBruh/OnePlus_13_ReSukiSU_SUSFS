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
grep -q '^  archive_final_zip:$' "$build_action" ||
  fail "build action must expose an opt-in final ZIP archive setting"
grep -A4 '^  archive_final_zip:$' "$build_action" | grep -q 'default: false' ||
  fail "final ZIP archive setting must default to false for existing workflows"
grep -q 'archive: \${{ inputs.archive_final_zip }}' "$build_action" ||
  fail "final ZIP upload must use the opt-in archive setting"
grep -q 'archive_final_zip: true' "$workflow" ||
  fail "OP13 release workflow must preserve the original final ZIP artifact"

python3 - "$workflow" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")

def require(snippet: str, message: str) -> None:
    if snippet not in text:
        raise SystemExit(message)

def reject(snippet: str, message: str) -> None:
    if snippet in release_section:
        raise SystemExit(message)

require("\n  release-op13-global:\n", "workflow must publish the successful OP13 build as a GitHub Release")
release_section = text[text.index("\n  release-op13-global:\n") :]

for snippet, message in [
    ("needs: build-op13-global", "release job must wait for the build job"),
    ("kernel_version: ${{ steps.build.outputs.kernel_version }}", "build job must export kernel version"),
    ("ksu_version: ${{ steps.build.outputs.ksu_version }}", "build job must export ReSukiSU version"),
    ("susfs_version: ${{ steps.build.outputs.susfs_version }}", "build job must export SUSFS version"),
    ("zip_name: ${{ steps.build.outputs.zip_name }}", "build job must export ZIP artifact name"),
    ("zip_sha256: ${{ steps.build.outputs.zip_sha256 }}", "build job must export ZIP SHA-256"),
    ("uses: actions/download-artifact@v5", "release job must download the already-uploaded artifact"),
    ("name: ${{ needs.build-op13-global.outputs.zip_name }}", "release job must download only the flashable ZIP artifact"),
    ("path: release-dist", "release job must download the ZIP into a release-only directory"),
    ("GH_TOKEN: ${{ github.token }}", "release job must use the workflow GitHub token for gh"),
    ("RUN_NUMBER: ${{ github.run_number }}", "release tag must include the workflow run number"),
    ("RUN_ATTEMPT: ${{ github.run_attempt }}", "release tag must include the workflow run attempt"),
    ("WORKFLOW_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}", "release body must include workflow URL"),
    ("op13-global-oos16-6.6.118-r${RUN_NUMBER}-a${RUN_ATTEMPT}", "release tag must be deterministic and unique per manual run attempt"),
    ("OP13 Global (CPH2653)", "release title/body must identify OP13 Global CPH2653"),
    ("OOS16 / kernel 6.6.118", "release title/body must state target OOS/kernel"),
    ("6.6.118-android15-8-g2e6b9c3812c5-ab15114928-4k", "release body must include expected KMI"),
    ("ReSukiSU: %s", "release body must include ReSukiSU version from build output"),
    ("SUSFS: %s", "release body must include SUSFS version from build output"),
    ("Package ZIP: `%s`", "release body must include package ZIP name"),
    ("SHA-256: `%s`", "release body must include ZIP SHA-256"),
    ("Workflow: %s", "release body must include workflow URL"),
    ("AnyKernel3 package, not a KernelSU module", "release body must warn about package type"),
    ("No .tzst cache asset belongs in this release.", "release body must reject cache assets"),
    ('gh release create "$release_tag" "$zip_path"', "release job must create a normal release with only the ZIP asset"),
    ('--target "$GITHUB_SHA"', "release tag must target the built commit"),
    ('--notes-file "$release_notes"', "release notes must be passed through a file"),
]:
    if snippet not in release_section and "steps.build.outputs" not in snippet:
        raise SystemExit(message)
    if "steps.build.outputs" in snippet and snippet not in text:
        raise SystemExit(message)

for snippet, message in [
    ("--draft", "release must not be a draft"),
    ("--prerelease", "release must not be a prerelease"),
    (".tzst\"", "release job must not upload a .tzst asset"),
    (".tzst'", "release job must not upload a .tzst asset"),
    ("<<EOF", "release notes must not use an unsafe heredoc"),
    ("<<'EOF'", "release notes must not use an unsafe heredoc"),
    ('<<"EOF"', "release notes must not use an unsafe heredoc"),
]:
    reject(snippet, message)
PY

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
