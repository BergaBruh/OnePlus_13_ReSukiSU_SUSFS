#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$repo_root" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import yaml

root = Path(sys.argv[1])
action = yaml.safe_load((root / ".github/actions/build-kernel/action.yml").read_text())
step = next(s for s in action["runs"]["steps"] if s["name"] == "Fetch SusFS and Other Dependencies")
script = step["run"]
helper = script[script.index("retry_fetch_archive() {"):script.index("retry_clone() {")]

with tempfile.TemporaryDirectory(prefix="susfs-download-test.") as tmp:
    base = Path(tmp)
    fixture = base / "fixture"
    for name in ("kernel_patches/include/linux/susfs.h", "kernel_patches/fs/susfs.c"):
        path = fixture / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("/* SUSFS fixture */\n")
    def git(*args):
        return subprocess.check_output(["git", "-C", str(fixture), *args], text=True).strip()
    git("init", "-q")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@local", "commit", "-qm", "fixture")
    sha = git("rev-parse", "HEAD")
    archive = base / "fixture.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(fixture / "kernel_patches", arcname="susfs4ksu-fixture/kernel_patches")

    binaries = base / "bin"
    binaries.mkdir()
    git_mock = binaries / "git"
    git_mock.write_text('''#!/bin/bash
set -eu
if [[ " $* " == *" fetch "* ]]; then
  requested="${@: -1}"
  printf '%s\n' "$requested" >> "$FETCH_REQUESTS"
  if [[ "$DOWNLOAD_MODE" == git-success ]]; then
    exec /usr/bin/git -C "$2" fetch --depth=1 --no-tags "$GIT_FIXTURE" "$requested"
  elif [[ "$DOWNLOAD_MODE" == mismatch ]]; then
    exec /usr/bin/git -C "$2" fetch --depth=1 --no-tags "$GIT_FIXTURE" "$FIXTURE_SHA"
  fi
  echo 'simulated Git transport failure' >&2
  exit 1
fi
exec /usr/bin/git "$@"
''')
    curl_mock = binaries / "curl"
    curl_mock.write_text('''#!/bin/bash
set -eu
output=''
while (( $# )); do
  if [[ "$1" == -o ]]; then output="$2"; shift 2; continue; fi
  if [[ "$1" == https://* ]]; then printf '%s\n' "$1" >> "$CURL_REQUESTS"; fi
  shift
done
case "$DOWNLOAD_MODE" in
  archive-success) cp "$ARCHIVE_FIXTURE" "$output" ;;
  invalid-archive) printf '<html>Access denied</html>' > "$output" ;;
  *) echo 'curl: (22) HTTP 403 from fixture' >&2; exit 22 ;;
esac
''')
    sleep_mock = binaries / "sleep"
    sleep_mock.write_text("#!/bin/bash\nexit 0\n")
    for path in (git_mock, curl_mock, sleep_mock):
        path.chmod(0o755)

    for mode, ref, success in [
        ("git-success", sha, True),
        ("archive-success", sha, True),
        ("invalid-archive", sha, False),
        ("all-failed", sha, False),
        ("mismatch", "0" * 40, False),
        ("invalid-ref", "main", False),
    ]:
        cwd = base / mode
        cwd.mkdir()
        requests = cwd / "fetch-requests"
        curl_requests = cwd / "curl-requests"
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                   DOWNLOAD_MODE=mode, GIT_FIXTURE=str(fixture), FIXTURE_SHA=sha,
                   ARCHIVE_FIXTURE=str(archive), FETCH_REQUESTS=str(requests),
                   CURL_REQUESTS=str(curl_requests))
        invocation = '\nretry_fetch_archive https://gitlab.com/simonpunk/susfs4ksu.git "$REQUESTED_SHA"\n'
        env["REQUESTED_SHA"] = ref
        result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + helper + invocation],
                                cwd=cwd, env=env, text=True, capture_output=True)
        if (result.returncode == 0) != success:
            raise SystemExit(f"{mode}: unexpected exit {result.returncode}\n{result.stdout}\n{result.stderr}")
        dest = cwd / "susfs4ksu"
        if success:
            for name in ("kernel_patches/include/linux/susfs.h", "kernel_patches/fs/susfs.c"):
                if not (dest / name).is_file():
                    raise SystemExit(f"{mode}: missing source file {name}")
        elif dest.exists():
            raise SystemExit(f"{mode}: failed download left a source directory")
        if mode == "git-success":
            actual = subprocess.check_output(["/usr/bin/git", "-C", str(dest), "rev-parse", "HEAD"], text=True).strip()
            if actual != sha or curl_requests.exists():
                raise SystemExit("Git success must verify SHA and skip the archive endpoint")
        if mode == "mismatch":
            if "differs from requested" not in result.stdout or curl_requests.exists():
                raise SystemExit("SHA mismatch must fail immediately without fallback")
        if mode == "invalid-ref" and requests.exists():
            raise SystemExit("mutable ref must be rejected before a network request")
        if requests.exists() and any(line != ref for line in requests.read_text().splitlines()):
            raise SystemExit(f"{mode}: fetch substituted another revision")
        if curl_requests.exists():
            expected = f"https://gitlab.com/simonpunk/susfs4ksu/-/archive/{ref}/susfs4ksu-{ref}.tar.gz"
            if curl_requests.read_text().strip() != expected:
                raise SystemExit(f"{mode}: archive URL must use the requested immutable SHA")
        if mode == "all-failed" and "HTTP 403" not in result.stderr:
            raise SystemExit("HTTP failure diagnostics must remain visible")
        print(f"PASS: SUSFS {mode}")
PY
