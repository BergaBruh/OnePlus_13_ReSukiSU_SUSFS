#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$repo_root" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml

root = Path(sys.argv[1])
action = yaml.safe_load((root / ".github/actions/build-kernel/action.yml").read_text())
steps = action["runs"]["steps"]
resukisu = next(step["run"] for step in steps if step["name"].startswith("Add ReSukiSU"))
ksu = next(step["run"] for step in steps if step["name"] == "Add KernelSU")

def git(cwd, *args):
    return subprocess.check_output(["git", "-C", str(cwd), *args], text=True).strip()

with tempfile.TemporaryDirectory(prefix="root-checkout-test.") as temp:
    base = Path(temp)
    fixture = base / "fixture"
    (fixture / "kernel").mkdir(parents=True)
    (fixture / "kernel/Makefile").write_text("# root driver fixture\n")
    git(fixture, "init", "-q")
    git(fixture, "add", ".")
    git(fixture, "-c", "user.name=Test", "-c", "user.email=test@local", "commit", "-qm", "fixture")
    actual = git(fixture, "rev-parse", "HEAD")
    setup = base / "setup.sh"
    setup.write_text('#!/bin/bash\nset -eu\ngit clone -q "$ROOT_DRIVER_FIXTURE" KernelSU\n')
    binaries = base / "bin"
    binaries.mkdir()
    curl = binaries / "curl"
    curl.write_text('''#!/bin/bash
set -eu
output=''
while (( $# )); do
  if [[ "$1" == -o ]]; then output="$2"; shift 2; continue; fi
  if [[ "$1" == https://* ]]; then printf '%s\n' "$1" >> "$CURL_REQUESTS"; fi
  shift
done
if [[ -n "$output" ]]; then cp "$ROOT_DRIVER_SETUP" "$output"; else cat "$ROOT_DRIVER_SETUP"; fi
''')
    curl.chmod(0o755)
    for label, script, requested, expected_success in [
        ("resukisu-exact", resukisu, actual, True),
        ("resukisu-mismatch", resukisu, "0" * 40, False),
        ("resukisu-default", resukisu, "", True),
        ("kernelsu-default", ksu, "", True),
    ]:
        workspace = base / label
        platform = workspace / "kernel_platform"
        config = platform / "common/arch/arm64/configs/gki_defconfig"
        config.parent.mkdir(parents=True)
        config.touch()
        git(platform, "init", "-q")
        artifacts = workspace / "artifacts"
        artifacts.mkdir()
        env_file = workspace / "github-env"
        env_file.touch()
        requests = workspace / "requests"
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                   ROOT_DRIVER_FIXTURE=str(fixture), ROOT_DRIVER_SETUP=str(setup),
                   CURL_REQUESTS=str(requests), KERNEL_PLATFORM_FOLDER=str(platform),
                   COMMON_KERNEL_FOLDER=str(platform / "common"), ARTIFACTS_FOLDER=str(artifacts),
                   OP_MODEL="OP13", OP_OS_VERSION="OOS16", GITHUB_ENV=str(env_file))
        env.pop("RESUKISU_REF", None)
        script = script.replace("${{ inputs.ksu_branch_or_hash }}", requested)
        script = script.replace("${{ env.KERNEL_VER }}", "6.6")
        result = subprocess.run(["bash", "-c", script], env=env, text=True, capture_output=True)
        if (result.returncode == 0) != expected_success:
            raise SystemExit(f"{label}: unexpected exit {result.returncode}\n{result.stdout}\n{result.stderr}")
        metadata = env_file.read_text()
        if expected_success and f"KSU_COMMIT_SHA={actual}" not in metadata:
            raise SystemExit(f"{label}: resolved SHA not exported")
        if not expected_success:
            if "differs from requested immutable ref" not in result.stdout or "KSU_COMMIT_SHA=" in metadata:
                raise SystemExit(f"{label}: mismatched SHA must fail before export")
        if label.startswith("resukisu"):
            ref = requested or "main"
            if requests.read_text().strip() != f"https://raw.githubusercontent.com/Baka-SU/BakaSU/{ref}/kernel/setup.sh":
                raise SystemExit(f"{label}: unexpected setup source")
        print(f"PASS: {label}")
PY
