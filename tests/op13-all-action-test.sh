#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/build-op13-all.yml"

expected_manifests=(
  "manifests/oos15/oneplus_13_6.6.30_v.xml"
  "manifests/oos15/oneplus_13_global_6.6.56_v.xml"
  "manifests/oos15/oneplus_13_global_v.xml"
  "manifests/oos15/oneplus_13_v.xml"
  "manifests/oos16/oneplus_13_global_6.6.118_w.xml"
  "manifests/oos16/oneplus_13_w.xml"
)
expected_configs=(
  "configs/oos15/OP13-6.6.30.json"
  "configs/oos15/OP13-CPH-6.6.56.json"
  "configs/oos15/OP13-CPH.json"
  "configs/oos15/OP13-PJZ.json"
  "configs/oos16/OP13-GLOBAL-6.6.118.json"
  "configs/oos16/OP13.json"
)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mapfile -t actual_manifests < <(git -C "$repo_root" ls-files 'manifests/**/*.xml' | sort)
expected_manifest_list=$(printf '%s\n' "${expected_manifests[@]}")
actual_manifest_list=$(printf '%s\n' "${actual_manifests[@]}")
[[ "$actual_manifest_list" == "$expected_manifest_list" ]] ||
  fail "tracked manifest inventory must be exactly the approved six files"

python3 - "$repo_root" "${expected_configs[@]}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for config_path in sys.argv[2:]:
    path = root / config_path
    if not path.is_file():
        raise SystemExit(f"missing approved config: {config_path}")
    with path.open(encoding="utf-8") as fh:
        config = json.load(fh)
    manifest = config.get("manifest")
    if not isinstance(manifest, str) or not manifest:
        raise SystemExit(f"{config_path}: missing manifest reference")
    matches = [candidate for candidate in (root / "manifests").rglob(manifest)]
    if len(matches) != 1:
        raise SystemExit(f"{config_path}: manifest reference must resolve exactly once: {manifest}")
PY

[[ -f "$workflow" ]] || fail "missing all-variant OP13 workflow"

python3 - "$workflow" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")

def require(pattern: str, message: str) -> None:
    if not re.search(pattern, text, re.MULTILINE):
        raise SystemExit(message)

def require_text(value: str, message: str) -> None:
    if value not in text:
        raise SystemExit(message)

expected_rows = [
    ("oos15-op13-6-6-30", "configs/oos15/OP13-6.6.30.json", "manifests/oos15/oneplus_13_6.6.30_v.xml", "manifest-specific; no region inferred"),
    ("oos15-op13-cph-6-6-56", "configs/oos15/OP13-CPH-6.6.56.json", "manifests/oos15/oneplus_13_global_6.6.56_v.xml", "CPH2649 IN, CPH2653 EU/GLO, CPH2655 NA/US"),
    ("oos15-op13-cph", "configs/oos15/OP13-CPH.json", "manifests/oos15/oneplus_13_global_v.xml", "CPH2649 IN, CPH2653 EU/GLO, CPH2655 NA/US"),
    ("oos15-op13-pjz", "configs/oos15/OP13-PJZ.json", "manifests/oos15/oneplus_13_v.xml", "PJZ110 CN"),
    ("oos16-op13-global-6-6-118", "configs/oos16/OP13-GLOBAL-6.6.118.json", "manifests/oos16/oneplus_13_global_6.6.118_w.xml", "CPH2649 IN, CPH2653 EU/GLO, CPH2655 NA/US"),
    ("oos16-op13", "configs/oos16/OP13.json", "manifests/oos16/oneplus_13_w.xml", "manifest-specific; no region inferred"),
]

require(r"^\s*push:\s*$", "workflow must retain a push trigger")
require(r"^\s*workflow_dispatch:\s*$", "workflow must retain workflow_dispatch")
for name, kind, default in [
    ("optimize_level", "choice", "O2"),
    ("clean_build", "boolean", "false"),
    ("debug", "boolean", "false"),
]:
    pattern = rf"(?ms)^\s{{6}}{name}:\s*$.*?^\s{{8}}type:\s*{kind}\s*$.*?^\s{{8}}default:\s*{default}\s*$"
    require(pattern, f"workflow_dispatch input {name} must preserve its type/default")

require(r"^\s{4}fail-fast:\s*false\s*$", "matrix strategy must set fail-fast: false")
require(r"^\s{6}include:\s*$", "matrix strategy must use an include list")

include_section = text[text.index("include:") :]
rows = re.findall(
    r"(?ms)^\s*-\s+slug:\s*([^\n]+)\n\s*config:\s*([^\n]+)\n\s*manifest:\s*([^\n]+)\n\s*compatibility:\s*([^\n]+)",
    include_section,
)
if rows != expected_rows:
    raise SystemExit(f"matrix include must equal the six approved rows; got {rows!r}")

require_text(".github/update-state/op13-upstreams.json", "workflow must retain the pinned upstream state source")
require_text(".sources.resukisu.sha", "workflow must retain the ReSukiSU state pin")
require_text(".sources.susfs.sha", "workflow must retain the SUSFS state pin")
require_text("ksu_branch_or_hash: ${{ steps.config.outputs.resukisu_sha }}", "workflow must pass the ReSukiSU state pin")
require_text("susfs_commit_hash_or_branch: ${{ steps.config.outputs.susfs_sha }}", "workflow must pass the SUSFS state pin")
require_text("op_config_json: ${{ steps.config.outputs.json }}", "workflow must pass the matrix config JSON to the build action")
require_text("archive_final_zip: false", "matrix builds must upload uniquely named ZIPs directly")
require_text("release-metadata-${{ matrix.slug }}.json", "each matrix build must write slugged release metadata")
require_text("op13-release-${{ matrix.slug }}", "each matrix build must use a slugged artifact name")

for slug, _, _, _ in expected_rows:
    require_text(slug, f"workflow is missing required slug {slug}")

require(r"^\s{2}publish:\s*$", "workflow must have one publish job")
publish_start = text.index("\n  publish:\n")
publish_section = text[publish_start:]
if "matrix:" in publish_section:
    raise SystemExit("publish must be a non-matrix job")
require_text("needs: build", "publish must depend on all matrix builds")
require_text("op13-all-r${RUN_NUMBER}-a${RUN_ATTEMPT}", "release tag must be dynamic and shared")
require_text("OnePlus 13 ReSukiSU + SUSFS builds r${RUN_NUMBER}", "release title must be dynamic and non-regional")
require_text("| Slug | Config | Manifest | Compatibility | OOS | Kernel/KMI | ReSukiSU | SUSFS | ZIP | SHA-256 |", "release body must generate the metadata table")
require_text("release-metadata-*.json", "publish must validate all six metadata files")
require_text("gh release create", "publish must create the release")
if len(re.findall(r"\bgh\s+release\s+create\b", text)) != 1:
    raise SystemExit("workflow must invoke gh release create exactly once")

print("PASS: OP13 all-variant action contract")
PY
