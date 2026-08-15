#!/usr/bin/env bash
set -euo pipefail

python - <<'PY'
from pathlib import Path
import yaml

root = Path.cwd()
action_path = root / ".github/actions/build-kernel/action.yml"
release_path = root / ".github/workflows/build-kernel-release.yml"
op13_all_path = root / ".github/workflows/build-op13-all.yml"

action_text = action_path.read_text()
release_text = release_path.read_text()
op13_all_text = op13_all_path.read_text()
action = yaml.safe_load(action_text)
release = yaml.safe_load(release_text)
op13_all = yaml.safe_load(op13_all_text)

retention = action.get("inputs", {}).get("artifact_retention_days", {})
if retention.get("default") != 90:
    raise SystemExit("build action must keep a 90-day default for manually downloaded ZIPs")
if "retention-days: ${{ inputs.artifact_retention_days }}" not in action_text:
    raise SystemExit("build action must make final ZIP retention configurable")
if "artifact_retention_days: ${{ inputs.make_release && 1 || 90 }}" not in release_text:
    raise SystemExit("release staging ZIPs must expire after one day while non-release builds retain the default")

release_steps = release["jobs"]["trigger-release"]["steps"]
steps_by_name = {step.get("name"): step for step in release_steps}
matrix_download = steps_by_name.get("📥 Download build matrix")
zip_download = steps_by_name.get("📥 Download release ZIPs")
if not matrix_download or matrix_download.get("with", {}).get("name") != "build-matrix":
    raise SystemExit("release must download the matrix explicitly")
if not zip_download or zip_download.get("with", {}).get("pattern") != "AK3_*":
    raise SystemExit("release must download only final AK3 ZIP artifacts")
if "🧹 Exclude ccache binary from release staging" in steps_by_name:
    raise SystemExit("release must not download ccache-binary merely to delete it")

tag_step = steps_by_name.get("🏷️ Generate release tag name")
if not tag_step or "git tag" in tag_step.get("run", "") or "git push origin" in tag_step.get("run", ""):
    raise SystemExit("release tag must not be created before artifact validation")
create_step = steps_by_name.get("🚀 Create GitHub Release")
if not create_step or '--target "$GITHUB_SHA"' not in create_step.get("run", ""):
    raise SystemExit("gh release create must atomically create the tag at the workflow commit")

all_steps = op13_all["jobs"]["build"]["steps"]
upload_step = next((step for step in all_steps if step.get("name") == "Upload verified release inputs"), None)
if not upload_step or upload_step.get("with", {}).get("retention-days") != 1:
    raise SystemExit("aggregate release staging artifacts must expire after one day")

print("PASS: release workflow optimization contract")
PY
