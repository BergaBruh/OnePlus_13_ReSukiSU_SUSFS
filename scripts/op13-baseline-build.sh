#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SOURCE_REMOTE="https://github.com/crdroidandroid/android_kernel_oneplus_sm8750.git"
readonly SOURCE_COMMIT="d7067f0ef3dd7c9a48818c80f9cc4e34920e4f83"
readonly EXPECTED_SOURCE_VERSION="6.6.118"
readonly WORKSPACE="${OP13_BASELINE_WORKDIR:-$REPO_ROOT/.op13-baseline}"
readonly MIN_FREE_KB=$((80 * 1024 * 1024))
readonly CLANG_REMOTE="https://git.codelinaro.org/clo/la/kernelplatform/prebuilts-master/clang/host/linux-x86.git"
readonly CLANG_COMMIT="b099698c583b8361ca771f3cc8d6af6f729f39b3"
readonly CLANG_VERSION="r510928"
readonly -a REQUIRED_HOST_TOOLS=(
  git make bc bison flex openssl perl python3 pahole file sha256sum df nproc tee
)

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

usage() {
  cat <<'EOF'
Usage: scripts/op13-baseline-build.sh <action>

Actions:
  fetch-source   Clone the pinned OP13 baseline source into .op13-baseline/source.
  fetch-toolchain Clone the pinned Android Clang toolchain into .op13-baseline/toolchains/clang.
  preflight      Check required host tools and available disk space.
  build          Build the source's sun 4K Image after all guards pass.
  verify-source  Verify the local source commit and Makefile version.
EOF
}

preflight_commands() {
  local command_name
  local missing=0

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf 'Missing required host command: %s\n' "$command_name" >&2
      missing=1
    fi
  done

  (( missing == 0 ))
}

preflight() {
  local header
  local filesystem
  local blocks
  local used
  local available_kb
  local capacity
  local mountpoint

  preflight_commands "${REQUIRED_HOST_TOOLS[@]}" || return

  {
    read -r header
    read -r filesystem blocks used available_kb capacity mountpoint
  } < <(df -Pk "$REPO_ROOT")

  [[ "$available_kb" =~ ^[0-9]+$ ]] || {
    fail "cannot determine available disk space for $REPO_ROOT"
    return
  }
  (( available_kb >= MIN_FREE_KB )) || {
    fail "insufficient free disk space: ${available_kb} KiB available, ${MIN_FREE_KB} KiB required"
    return
  }

  printf 'Preflight passed: %s KiB available (minimum %s KiB)\n' "$available_kb" "$MIN_FREE_KB"
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

verify_toolchain() {
  local toolchain_dir=$1
  local clang_version=$2
  local clang="$toolchain_dir/clang-$clang_version/bin/clang"

  [[ -x "$clang" ]] || {
    fail "missing Android Clang $clang_version: $clang"
    return
  }

  printf 'Verified Android Clang %s: %s\n' "$clang_version" "$clang"
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

fetch_toolchain() {
  local toolchain_dir="$WORKSPACE/toolchains/clang"
  local actual_commit

  if [[ -e "$toolchain_dir" ]]; then
    if [[ -d "$toolchain_dir/.git" ]]; then
      actual_commit=$(git -C "$toolchain_dir" rev-parse HEAD) || {
        fail "cannot resolve toolchain commit: $toolchain_dir"
        return
      }
      [[ "$actual_commit" == "$CLANG_COMMIT" ]] || {
        fail "unexpected toolchain commit: got $actual_commit, expected $CLANG_COMMIT"
        return
      }
      verify_toolchain "$toolchain_dir" "$CLANG_VERSION"
      return
    fi

    [[ -d "$toolchain_dir" ]] || {
      fail "refusing to use non-directory toolchain path: $toolchain_dir"
      return
    }
    [[ -z "$(find "$toolchain_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || {
      fail "refusing to use non-empty non-Git toolchain directory: $toolchain_dir"
      return
    }
  fi

  mkdir -p "$WORKSPACE/toolchains"
  git clone --filter=blob:none "$CLANG_REMOTE" "$toolchain_dir"
  git -C "$toolchain_dir" checkout --detach "$CLANG_COMMIT"
  verify_toolchain "$toolchain_dir" "$CLANG_VERSION"
}

verify_sun_build_inputs() {
  local source_dir=$1
  local config
  local -a configs=(
    arch/arm64/configs/gki_defconfig
    arch/arm64/configs/vendor/sun_perf.config
    arch/arm64/configs/consolidate.fragment
    arch/arm64/configs/vendor/sun_consolidate.config
    scripts/kconfig/merge_config.sh
  )

  for config in "${configs[@]}"; do
    [[ -f "$source_dir/$config" ]] || {
      fail "missing required sun 4K build input: $source_dir/$config"
      return
    }
  done
}

run_logged() {
  local log_file=$1
  shift

  {
    printf 'Command:'
    printf ' %q' "$@"
    printf '\n'
  } >>"$log_file"
  "$@" 2>&1 | tee -a "$log_file"
}

build() {
  local source_dir="$WORKSPACE/source"
  local toolchain_dir="$WORKSPACE/toolchains/clang"
  local toolchain_bin="$toolchain_dir/clang-$CLANG_VERSION/bin"
  local out_dir="$WORKSPACE/out/sun-4k"
  local log_dir="$WORKSPACE/logs"
  local log_file
  local jobs="${OP13_BASELINE_JOBS:-$(nproc)}"

  verify_source "$source_dir" "$SOURCE_COMMIT" "$EXPECTED_SOURCE_VERSION" || return
  preflight || return
  verify_toolchain "$toolchain_dir" "$CLANG_VERSION" || return
  verify_sun_build_inputs "$source_dir" || return

  mkdir -p "$out_dir" "$log_dir"
  log_file="$log_dir/sun-4k-$(date -u +%Y%m%dT%H%M%SZ).log"

  export PATH="$toolchain_bin:$PATH"
  run_logged "$log_file" env KCONFIG_CONFIG="$out_dir/.config" \
    "$source_dir/scripts/kconfig/merge_config.sh" -m -r -y \
    "$source_dir/arch/arm64/configs/gki_defconfig" \
    "$source_dir/arch/arm64/configs/vendor/sun_perf.config" \
    "$source_dir/arch/arm64/configs/consolidate.fragment" \
    "$source_dir/arch/arm64/configs/vendor/sun_consolidate.config"
  run_logged "$log_file" make -C "$source_dir" O="$out_dir" ARCH=arm64 LLVM=1 olddefconfig
  grep -qx 'CONFIG_ARM64_4K_PAGES=y' "$out_dir/.config" || {
    fail "sun build configuration did not resolve to 4K pages"
    return
  }
  run_logged "$log_file" make -C "$source_dir" O="$out_dir" ARCH=arm64 LLVM=1 -j"$jobs" Image

  [[ -s "$out_dir/arch/arm64/boot/Image" ]] || {
    fail "sun 4K build completed without Image output"
    return
  }
  printf 'Built sun 4K Image: %s\nLog: %s\n' "$out_dir/arch/arm64/boot/Image" "$log_file"
}

main() {
  local action=${1:-}

  case "$action" in
    preflight)
      [[ $# -eq 1 ]] || {
        fail "preflight does not accept arguments"
        return
      }
      preflight
      ;;
    fetch-toolchain)
      [[ $# -eq 1 ]] || {
        fail "fetch-toolchain does not accept arguments"
        return
      }
      fetch_toolchain
      ;;
    fetch-source)
      [[ $# -eq 1 ]] || {
        fail "fetch-source does not accept arguments"
        return
      }
      fetch_source
      ;;
    build)
      [[ $# -eq 1 ]] || {
        fail "build does not accept arguments"
        return
      }
      build
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
