#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SOURCE_REMOTE="https://github.com/crdroidandroid/android_kernel_oneplus_sm8750.git"
readonly SOURCE_COMMIT="d7067f0ef3dd7c9a48818c80f9cc4e34920e4f83"
readonly EXPECTED_SOURCE_VERSION="6.6.118"
readonly WORKSPACE="${OP13_BASELINE_WORKDIR:-$REPO_ROOT/.op13-baseline}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

usage() {
  cat <<'EOF'
Usage: scripts/op13-baseline-build.sh <action>

Actions:
  fetch-source   Clone the pinned OP13 baseline source into .op13-baseline/source.
  verify-source  Verify the local source commit and Makefile version.
EOF
}

verify_source() {
  local source_dir=$1
  local expected_commit=$2
  local expected_version=$3
  local actual_commit
  local major
  local minor
  local patch

  [[ -d "$source_dir/.git" ]] || {
    fail "source directory is not a Git checkout: $source_dir"
    return
  }
  [[ -f "$source_dir/Makefile" ]] || {
    fail "source Makefile is missing: $source_dir/Makefile"
    return
  }

  actual_commit=$(git -C "$source_dir" rev-parse HEAD) || {
    fail "cannot resolve source commit: $source_dir"
    return
  }
  [[ "$actual_commit" == "$expected_commit" ]] || {
    fail "unexpected source commit: got $actual_commit, expected $expected_commit"
    return
  }

  IFS=. read -r major minor patch <<<"$expected_version"
  [[ -n "$major" && -n "$minor" && -n "$patch" ]] || {
    fail "invalid expected version: $expected_version"
    return
  }

  grep -Eq "^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*$major[[:space:]]*$" "$source_dir/Makefile" ||
    { fail "unexpected kernel VERSION in $source_dir/Makefile"; return; }
  grep -Eq "^[[:space:]]*PATCHLEVEL[[:space:]]*=[[:space:]]*$minor[[:space:]]*$" "$source_dir/Makefile" ||
    { fail "unexpected kernel PATCHLEVEL in $source_dir/Makefile"; return; }
  grep -Eq "^[[:space:]]*SUBLEVEL[[:space:]]*=[[:space:]]*$patch[[:space:]]*$" "$source_dir/Makefile" ||
    { fail "unexpected kernel SUBLEVEL in $source_dir/Makefile"; return; }

  printf 'Verified OP13 baseline source: %s (%s)\n' "$expected_version" "$actual_commit"
}

fetch_source() {
  local source_dir="$WORKSPACE/source"

  if [[ -e "$source_dir" ]]; then
    if [[ -d "$source_dir/.git" ]]; then
      verify_source "$source_dir" "$SOURCE_COMMIT" "$EXPECTED_SOURCE_VERSION"
      return
    fi

    [[ -d "$source_dir" ]] || {
      fail "refusing to use non-directory source path: $source_dir"
      return
    }

    if [[ -n "$(find "$source_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      fail "refusing to use non-empty non-Git source directory: $source_dir"
      return
    fi
  fi

  mkdir -p "$WORKSPACE"
  git clone --filter=blob:none "$SOURCE_REMOTE" "$source_dir"
  git -C "$source_dir" checkout --detach "$SOURCE_COMMIT"
  verify_source "$source_dir" "$SOURCE_COMMIT" "$EXPECTED_SOURCE_VERSION"
}

main() {
  local action=${1:-}

  case "$action" in
    fetch-source)
      [[ $# -eq 1 ]] || {
        fail "fetch-source does not accept arguments"
        return
      }
      fetch_source
      ;;
    verify-source)
      [[ $# -eq 1 ]] || {
        fail "verify-source does not accept arguments"
        return
      }
      verify_source "$WORKSPACE/source" "$SOURCE_COMMIT" "$EXPECTED_SOURCE_VERSION"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      fail "unknown or missing action: ${action:-<none>}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
