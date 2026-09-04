#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_path="$repo_root/.github/update-state/op13-experimental-resukisu-susfs.json"
workflow_path="$repo_root/.github/workflows/build-op13-experimental-resukisu-susfs.yml"

python3 - "$repo_root" "$state_path" "$workflow_path" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
state_path = Path(sys.argv[2])
workflow_path = Path(sys.argv[3])
action_path = root / ".github/actions/build-kernel/action.yml"

expected = {
    "firmware": "16.0.9.401(EX01)",
    "config": "configs/oos16/OP13-GLOBAL-6.6.118.json",
    "manifest": "manifests/oos16/oneplus_13_global_6.6.118_w.xml",
    "kernel_common": "e1b346b6b4f4096eb342ae3684838a942fd6f6c4",
    "kernel_modules": "d50b305f7da9e14715a25120a4ac7b1a4b8b97c3",
    "resukisu": "9d0ff6aea9e25fc7dd26f4643175a41f68375e5e",
    "susfs": "937215cb3a1b1f333d764c366c7a49972fa8e7a0",
}

if not state_path.is_file():
    raise SystemExit(f"missing experimental state file: {state_path.relative_to(root)}")
if not workflow_path.is_file():
    raise SystemExit(f"missing experimental workflow: {workflow_path.relative_to(root)}")

state = json.loads(state_path.read_text(encoding="utf-8"))
validation = state.get("validation")
if validation != {
    "experimental": True,
    "supported": False,
    "publish_release": False,
    "flash_permitted": False,
}:
    raise SystemExit("experimental state must explicitly prohibit support, publication, and flashing")

target = state.get("target", {})
if target.get("firmware_version") != expected["firmware"]:
    raise SystemExit("experimental state must pin OOS 16.0.9.401(EX01)")
if target.get("config") != expected["config"]:
    raise SystemExit("experimental state must pin only the OP13 Global 6.6.118 config")
if target.get("manifest") != expected["manifest"]:
    raise SystemExit("experimental state must pin the matching OP13 Global manifest")

sources = state.get("sources", {})
for source_name, sha_key in [
    ("kernel_common", "kernel_common"),
    ("kernel_modules", "kernel_modules"),
    ("resukisu", "resukisu"),
    ("susfs", "susfs"),
]:
    source = sources.get(source_name, {})
    if source.get("sha") != expected[sha_key]:
        raise SystemExit(f"experimental state must pin {source_name} to {expected[sha_key]}")

if sources.get("resukisu", {}).get("repository") != "ReSukiSU/ReSukiSU":
    raise SystemExit("experimental state must identify the ReSukiSU repository")
if sources.get("susfs", {}).get("repository") != "https://gitlab.com/simonpunk/susfs4ksu":
    raise SystemExit("experimental state must identify the SUSFS repository")
if sources.get("susfs", {}).get("version") != "v2.3.0":
    raise SystemExit("experimental state must record SUSFS v2.3.0")

workflow = workflow_path.read_text(encoding="utf-8")
if not re.search(r"(?m)^\s*workflow_dispatch:\s*$", workflow):
    raise SystemExit("experimental workflow must be manual only")
if re.search(r"(?m)^\s*(push|pull_request|schedule):", workflow):
    raise SystemExit("experimental workflow must not have an automatic trigger")
if not re.search(r"(?ms)^permissions:\s*\n\s+contents:\s*read\s*$", workflow):
    raise SystemExit("experimental workflow must use contents: read only")
if not re.search(r"(?ms)^jobs:\s*\n\s+build:", workflow):
    raise SystemExit("experimental workflow must contain a single build job")
if re.search(r"(?m)^\s{2,}[A-Za-z0-9_-]+:\s*$", workflow.split("jobs:", 1)[1]) and len(re.findall(r"(?m)^\s{2}[A-Za-z0-9_-]+:\s*$", workflow.split("jobs:", 1)[1])) != 1:
    raise SystemExit("experimental workflow must not add a publication job")

required_literals = [
    expected["config"],
    expected["manifest"],
    expected["resukisu"],
    expected["susfs"],
    "uses: ./.github/actions/build-kernel",
    "ksu_type: ReSukiSU",
    "clean: true",
    "debug: true",
    "upload_final_zip: false",
    "EXPECTED_RESUKISU_SHA",
    "EXPECTED_SUSFS_SHA",
    "ACTUAL_RESUKISU_SHA: ${{ steps.build.outputs.ksu_commit_sha }}",
    "ACTUAL_SUSFS_SHA: ${{ steps.build.outputs.susfs_commit_sha }}",
    '[[ "$ACTUAL_RESUKISU_SHA" == "$EXPECTED_RESUKISU_SHA" ]]',
    '[[ "$ACTUAL_SUSFS_SHA" == "$EXPECTED_SUSFS_SHA" ]]',
]
for literal in required_literals:
    if literal not in workflow:
        raise SystemExit(f"experimental workflow missing required contract literal: {literal}")

if workflow.count("actions/upload-artifact@v7") != 1:
    raise SystemExit("experimental workflow may upload only the inspection ZIP; diagnostics come from debug=true")
if "OP13/artifacts/${{ steps.build.outputs.zip_name }}" not in workflow:
    raise SystemExit("experimental workflow must upload the generated ZIP only for inspection")

for forbidden in [
    r"\bgh\s+release\s+create\b",
    r"\bfastboot\b",
    r"\badb\b",
    r"\bflash(?:ing|ed)?\b",
    r"actions/create-release@",
]:
    if re.search(forbidden, workflow, flags=re.IGNORECASE):
        raise SystemExit(f"experimental workflow contains forbidden publication or flash capability: {forbidden}")

action = action_path.read_text(encoding="utf-8")
if '[[ "$RESUKISU_REF" =~ ^[0-9a-f]{40}$ ]]' not in action:
    raise SystemExit("build action must validate immutable ReSukiSU refs")
if '[[ "$KSU_COMMIT_SHA" == "$RESUKISU_REF" ]]' not in action:
    raise SystemExit("build action must verify the checked out ReSukiSU HEAD")

print("PASS: experimental OP13 ReSukiSU/SUSFS workflow contract")
PY
