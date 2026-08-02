#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/build-op13-all.yml"
build_action="$repo_root/.github/actions/build-kernel/action.yml"

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

mapfile -t actual_op13_configs < <(
  git -C "$repo_root" ls-files 'configs/oos15/*.json' 'configs/oos16/*.json' |
    awk -F/ '$3 ~ /^OP13(-.*)?\.json$/ { print }' | sort
)
expected_config_list=$(printf '%s\n' "${expected_configs[@]}")
actual_op13_config_list=$(printf '%s\n' "${actual_op13_configs[@]}")
[[ "$actual_op13_config_list" == "$expected_config_list" ]] ||
  fail "tracked base OP13 config inventory must be exactly the approved six files"

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
    raw = path.read_text(encoding="utf-8")
    if '"module_overlay": false' not in raw:
        raise SystemExit(f'{config_path}: must set exact "module_overlay": false')
    if config.get("module_overlay") is not False:
        raise SystemExit(f"{config_path}: module_overlay must be boolean false")
    manifest = config.get("manifest")
    if not isinstance(manifest, str) or not manifest:
        raise SystemExit(f"{config_path}: missing manifest reference")
    matches = [candidate for candidate in (root / "manifests").rglob(manifest)]
    if len(matches) != 1:
        raise SystemExit(f"{config_path}: manifest reference must resolve exactly once: {manifest}")
PY

jq -e '.susfs == true' "$repo_root/configs/oos15/OP13-6.6.30.json" >/dev/null ||
  fail "configs/oos15/OP13-6.6.30.json must keep susfs enabled"
jq -e '.hmbird == true' "$repo_root/configs/oos16/OP13.json" >/dev/null ||
  fail "configs/oos16/OP13.json must keep hmbird enabled"

[[ -f "$workflow" ]] || fail "missing all-variant OP13 workflow"
[[ -f "$build_action" ]] || fail "missing build-kernel composite action"

mapfile -t tracked_workflows < <(
  git -C "$repo_root" ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml'
)

python3 - "$build_action" "$workflow" "$repo_root" "${tracked_workflows[@]}" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

action_text = Path(sys.argv[1]).read_text(encoding="utf-8")
workflow_path = Path(sys.argv[2])
workflow_text = workflow_path.read_text(encoding="utf-8")
repo_root = Path(sys.argv[3])

for relative_path in sys.argv[4:]:
    caller_path = repo_root / relative_path
    if caller_path == workflow_path:
        continue
    caller_text = caller_path.read_text(encoding="utf-8")
    if re.search(r"(?m)^\s*upload_final_zip:\s*false\s*$", caller_text):
        raise SystemExit(
            f"only build-op13-all.yml may set upload_final_zip: false: {relative_path}"
        )

input_match = re.search(
    r"(?ms)^  upload_final_zip:\s*$\n(?P<body>.*?)(?=^  [A-Za-z_][A-Za-z0-9_]*:\s*$|^outputs:\s*$)",
    action_text,
)
if not input_match:
    raise SystemExit("build action must declare upload_final_zip input")
if not re.search(r"(?m)^    default:\s*'true'\s*$", input_match.group("body")):
    raise SystemExit("upload_final_zip must default to 'true' for backward compatibility")

slug_input = re.search(
    r"(?ms)^  artifact_slug:\s*$\n(?P<body>.*?)(?=^  [A-Za-z_][A-Za-z0-9_]*:\s*$|^outputs:\s*$)",
    action_text,
)
if not slug_input:
    raise SystemExit("build action must declare the optional artifact_slug input")
if not re.search(r"(?m)^    required:\s*false\s*$", slug_input.group("body")):
    raise SystemExit("artifact_slug must remain optional for existing action callers")
if not re.search(r"(?m)^    default:\s*''\s*$", slug_input.group("body")):
    raise SystemExit("artifact_slug must default to the empty legacy-name behavior")

if re.search(r"(?ms)^  module_overlay:\s*$", action_text):
    raise SystemExit("module_overlay must come only from op_config_json, not a composite action input")

parse_step = re.search(
    r"(?ms)^    - name:\s*Parse op_config_json\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not parse_step:
    raise SystemExit("build action must retain the Parse op_config_json step")
parse_body = parse_step.group("body")
for required, message in [
    ('has("module_overlay")', "missing module_overlay must be detected explicitly"),
    ('(.module_overlay | type) == "boolean"', "module_overlay must be validated as a JSON boolean before export"),
    ('::error::op_config_json field \'module_overlay\' must be a JSON boolean true or false.', "invalid module_overlay JSON type must emit an actionable error"),
    ('echo "OP_MODULE_OVERLAY=false" >> "$GITHUB_ENV"', "missing module_overlay must export OP_MODULE_OVERLAY=false"),
]:
    if required not in parse_body:
        raise SystemExit(message)
type_check = parse_body.find('(.module_overlay | type) == "boolean"')
env_export = parse_body.find("jq -r 'to_entries[]")
if type_check == -1 or env_export == -1 or not type_check < env_export:
    raise SystemExit("module_overlay JSON type must be checked before exporting config entries to GITHUB_ENV")

for value in ('"true"', '"false"'):
    rejected = subprocess.run(
        ["jq", "-e", '(.module_overlay | type) == "boolean"'],
        input=f'{{"module_overlay": {value}}}',
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if rejected.returncode == 0:
        raise SystemExit(f"module_overlay string {value} must not satisfy the JSON boolean predicate")

validate_step = re.search(
    r"(?ms)^    - name:\s*Validate Inputs\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not validate_step:
    raise SystemExit("build action must retain the Validate Inputs step")
validate_body = validate_step.group("body")
for required, message in [
    ('module_overlay="${OP_MODULE_OVERLAY:-false}"', "module_overlay must default independently to false during validation"),
    ("Input 'module_overlay' must be 'true' or 'false'. Got: '$module_overlay'", "module_overlay must have boolean-only validation"),
]:
    if required not in validate_body:
        raise SystemExit(message)
module_overlay_assignment = validate_body.find('module_overlay="${OP_MODULE_OVERLAY:-false}"')
optimize_validation = validate_body.find('case "$optimize"')
if module_overlay_assignment == -1 or optimize_validation == -1:
    raise SystemExit("module_overlay validation must be in the existing input-validation block")
if "OP_CUSTOM_PATCHES" in validate_body[module_overlay_assignment:optimize_validation]:
    raise SystemExit("module_overlay validation must not inherit from custom_patches")

susfs_step = re.search(
    r"(?ms)^    - name:\s*Apply SUSFS Patches\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not susfs_step:
    raise SystemExit("build action must retain the Apply SUSFS Patches step")
susfs_body = susfs_step.group("body")
susfs_patch = 'patch -p1 --forward < "$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_${{ env.SUSFS_KERNEL_BRANCH }}.patch"'
compat_decl_check = "grep -qF '__fold_filemap_fixup_entry' \"$COMMON_KERNEL_FOLDER/include/linux/page_size_compat.h\""
compat_call_delete = "sed -i '/^[[:space:]]*__fold_filemap_fixup_entry(&((struct proc_maps_private \\*)m->private)->iter, &end);[[:space:]]*$/d'"
susfs_revert_marker = "# Revert Fake kernel patch"
susfs_patch_idx = susfs_body.find(susfs_patch)
compat_decl_idx = susfs_body.find(compat_decl_check)
compat_delete_match = re.search(
    re.escape(compat_call_delete) + r"\s+(?:\./)?fs/proc/task_mmu\.c(?:\s|$)",
    susfs_body,
)
compat_delete_idx = compat_delete_match.start() if compat_delete_match else -1
susfs_revert_idx = susfs_body.find(susfs_revert_marker)
if min(susfs_patch_idx, compat_decl_idx, compat_delete_idx, susfs_revert_idx) == -1:
    raise SystemExit("SUSFS android15-6.6 compatibility recovery must check page_size_compat.h and delete the stale task_mmu.c fixup call from fs/proc/task_mmu.c")
if not susfs_patch_idx < compat_decl_idx < compat_delete_idx < susfs_revert_idx:
    raise SystemExit("SUSFS compatibility recovery must run after the SUSFS patch attempt and before fake-patch rollback")
susfs_compat_region = susfs_body[compat_delete_idx:susfs_revert_idx]
stale_fixup_call = "__fold_filemap_fixup_entry(&((struct proc_maps_private *)m->private)->iter, &end);"
postcondition = re.search(
    r"(?ms)if\s+grep -qF "
    + re.escape("'" + stale_fixup_call + "'")
    + r"\s+(?:\./)?fs/proc/task_mmu\.c\s+&&\s+!\s+grep -qF '__fold_filemap_fixup_entry' \"\$COMMON_KERNEL_FOLDER/include/linux/page_size_compat\.h\";\s*then\s*$"
    + r"(?P<body>.*?)(?=^\s*fi\s*$)",
    susfs_compat_region,
)
if not postcondition:
    raise SystemExit("SUSFS compatibility postcondition must fail only when the exact task_mmu.c call remains and the page_size_compat.h declaration is absent")
if "::error::" not in postcondition.group("body") or "exit 1" not in postcondition.group("body"):
    raise SystemExit("SUSFS compatibility postcondition must emit ::error:: and exit 1")

ccache_step = re.search(
    r"(?ms)^    - name:\s*Check and Prepare Caches\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not ccache_step:
    raise SystemExit("build action must retain the Check and Prepare Caches step")
ccache_body = ccache_step.group("body")
if 'ccache --set-config=extra_files_to_hash=""' not in ccache_body:
    raise SystemExit("ccache setup must reset extra_files_to_hash for every run before overlay can override it")

apply_other_step = re.search(
    r"(?ms)^    - name:\s*Apply Other Patches\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not apply_other_step:
    raise SystemExit("build action must retain the Apply Other Patches step")
apply_other_body = apply_other_step.group("body")
for forbidden, message in [
    ("oneplus/module_overlay", "Apply Other Patches must not patch module_overlay"),
    ("convert_overlay.sh", "Apply Other Patches must not run module_overlay conversion setup"),
    ("module_overlay/modules", "Apply Other Patches must not copy module_overlay modules"),
    ("extra_files_to_hash", "Apply Other Patches must not own module_overlay ccache hashing"),
]:
    if forbidden in apply_other_body:
        raise SystemExit(message)
fengchi_failure = re.search(
    r"(?ms)if ! patch -p1 --fuzz=2 < \"\$FENGCHI_DIR/fengchi_\$\{HMBIRD_MODEL\}_\$\{HMBIRD_OS\}\.patch\"; then\s*$\n(?P<body>.*?)(?=^          fi\s*$)",
    apply_other_body,
)
if not fengchi_failure:
    raise SystemExit("Apply Other Patches must retain the failed Fengchi patch branch")
fengchi_failure_body = fengchi_failure.group("body")
old_reject_idx = fengchi_failure_body.find("grep -qF 'sched_ext_free(tsk);' kernel/fork.c.rej")
new_reject_idx = fengchi_failure_body.find("grep -qF 'hmbird_free(tsk);' kernel/fork.c.rej")
replace_idx = fengchi_failure_body.find("sed -i 's/sched_ext_free(tsk);/hmbird_free(tsk);/' kernel/fork.c")
new_hook_match = re.search(
    re.escape("grep -qF 'hmbird_free(tsk);' kernel/fork.c") + r"(?:\s|$)",
    fengchi_failure_body,
)
old_hook_match = re.search(
    re.escape("! grep -qF 'sched_ext_free(tsk);' kernel/fork.c") + r"(?:\s|$)",
    fengchi_failure_body,
)
new_hook_idx = new_hook_match.start() if new_hook_match else -1
old_hook_idx = old_hook_match.start() if old_hook_match else -1
handled_reject_idx = fengchi_failure_body.find("rm -f kernel/fork.c.rej")
remaining_reject_match = re.search(
    r"(?ms)if\s+\[\s+-n\s+\"\$\(find \. -name '\*\.rej' -print -quit\)\"\s+\];\s*then\s*$"
    r"(?P<body>.*?)(?=^\s*fi\s*$)",
    fengchi_failure_body,
)
remaining_reject_idx = remaining_reject_match.start() if remaining_reject_match else -1
ordered_hmbird_indexes = [
    old_reject_idx,
    new_reject_idx,
    replace_idx,
    new_hook_idx,
    old_hook_idx,
    handled_reject_idx,
    remaining_reject_idx,
]
if min(ordered_hmbird_indexes) == -1:
    raise SystemExit("HMBIRD Fengchi recovery must prove reject evidence, replace the fork hook, verify new/old hook state, remove only kernel/fork.c.rej, and check remaining rejects")
if ordered_hmbird_indexes != sorted(ordered_hmbird_indexes) or len(set(ordered_hmbird_indexes)) != len(ordered_hmbird_indexes):
    raise SystemExit("HMBIRD Fengchi recovery checks must run in strict evidence, replace, verify, handled-reject, remaining-reject order")
if 'find . -name "*.rej" -delete' in fengchi_failure_body:
    raise SystemExit("HMBIRD Fengchi recovery must not delete all reject files generically")
remaining_reject_region = fengchi_failure_body[handled_reject_idx:]
if "|| true" in remaining_reject_region or re.search(r"find \. -name ['\"]\*\.rej['\"] -delete", remaining_reject_region):
    raise SystemExit("HMBIRD Fengchi recovery remaining-reject region must not mask failures or delete rejects generically")
if not remaining_reject_match or "exit 1" not in remaining_reject_match.group("body"):
    raise SystemExit("HMBIRD Fengchi recovery must use find . -name '*.rej' -print -quit and fail if any unhandled reject files remain")

module_overlay_step = re.search(
    r"(?ms)^    - name:\s*Apply Module Overlay\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not module_overlay_step:
    raise SystemExit("build action must have a standalone Apply Module Overlay step")
module_overlay_body = module_overlay_step.group("body")
for required, message in [
    ("if: ${{ env.OP_MODULE_OVERLAY == 'true' }}", "module overlay step must be gated only by OP_MODULE_OVERLAY"),
    ('MIN_VERSION="5.16"', "module overlay step must preserve the existing kernel-version eligibility check"),
    ('overlay_patch="$KERNEL_PATCHES_FOLDER/oneplus/module_overlay/0001-module-Add-module-intercept-and-overlay-mechanism.patch"', "module overlay step must name the exact overlay patch payload"),
    ('overlay_modules_dir="$KERNEL_PATCHES_FOLDER/oneplus/module_overlay/modules"', "module overlay step must name the exact overlay modules payload"),
    ('::error::Missing module overlay patch: $overlay_patch', "module overlay step must fail with the missing patch path"),
    ('::error::Missing module overlay modules directory: $overlay_modules_dir', "module overlay step must fail with the missing modules path"),
    ('ccache --set-config=extra_files_to_hash="$copied_modules"', "module overlay step must preserve ccache hashing for copied overlay modules"),
]:
    if required not in module_overlay_body:
        raise SystemExit(message)
for guard, message in [
    ('[ ! -f "$overlay_patch" ]', "module overlay patch file guard must exist"),
    ('[ ! -d "$overlay_modules_dir" ]', "module overlay modules directory guard must exist"),
]:
    if guard not in module_overlay_body:
        raise SystemExit(message)
first_overlay_patch = module_overlay_body.find('patch -p1 -F 3 < "$overlay_patch"')
patch_guard = module_overlay_body.find('[ ! -f "$overlay_patch" ]')
modules_guard = module_overlay_body.find('[ ! -d "$overlay_modules_dir" ]')
if min(first_overlay_patch, patch_guard, modules_guard) == -1:
    raise SystemExit("module overlay guard ordering check could not locate required commands")
if not (patch_guard < first_overlay_patch and modules_guard < first_overlay_patch):
    raise SystemExit("module overlay payload guards must run before the first patch command mutates the kernel tree")
if action_text.count('ccache --set-config=extra_files_to_hash=') != 2:
    raise SystemExit("ccache extra_files_to_hash must be reset once in setup and overridden only by module overlay")
if not (ccache_step.start() < module_overlay_step.start()):
    raise SystemExit("ccache extra_files_to_hash reset must occur before the module overlay step")

path_step = re.search(
    r"(?ms)^    - name:\s*Set Dir Paths\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not path_step:
    raise SystemExit("build action must retain the Set Dir Paths step")
path_body = path_step.group("body")
if not re.search(
    r"(?m)^        ARTIFACT_SLUG:\s*\$\{\{ inputs\.artifact_slug \}\}\s*$",
    path_body,
):
    raise SystemExit("artifact_slug must enter shell through an environment variable")
path_run = path_body[path_body.index("      run: |") :]
if "${{ inputs.artifact_slug }}" in path_run:
    raise SystemExit("artifact_slug must not be interpolated directly into shell source")
if not re.search(r'(?m)^        DEBUG_ARTIFACT_SUFFIX=""$', path_run):
    raise SystemExit("empty artifact_slug must preserve the exact legacy debug basename")
if not re.search(
    r'(?m)^        if \[\[ -n "\$ARTIFACT_SLUG" && ! "\$ARTIFACT_SLUG" =~ \^\[A-Za-z0-9\._-\]\+\$ \]\]; then$',
    path_run,
):
    raise SystemExit("non-empty artifact_slug must be validated against the safe basename alphabet")
if not re.search(
    r'(?m)^          DEBUG_ARTIFACT_SUFFIX="_\$ARTIFACT_SLUG"$', path_run
):
    raise SystemExit("validated artifact_slug must derive an underscore-prefixed debug suffix")
if not re.search(
    r'(?m)^        DEBUG_ZIP_NAME="debug_\$\{OP_MODEL\}_\$\{OP_OS_VERSION\}\$\{DEBUG_ARTIFACT_SUFFIX\}\.zip"$',
    path_run,
):
    raise SystemExit("debug ZIP basename must consume the optional validated suffix")

upload_step = re.search(
    r"(?ms)^    - name:\s*Upload Artifacts\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not upload_step:
    raise SystemExit("build action must retain the Upload Artifacts step")
if not re.search(
    r"(?m)^      if:\s*.*inputs\.upload_final_zip\s*==\s*'true'.*$",
    upload_step.group("body"),
):
    raise SystemExit("Upload Artifacts condition must require inputs.upload_final_zip == 'true'")

debug_upload_step = re.search(
    r"(?ms)^    - name:\s*Upload Debug Artifacts\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not debug_upload_step or not re.search(
    r"(?m)^        name:\s*\$\{\{ env\.DEBUG_ZIP_NAME \}\}\s*$",
    debug_upload_step.group("body"),
):
    raise SystemExit("debug artifact upload name must consume the suffix-aware debug ZIP basename")

build_step = re.search(
    r"(?ms)^        uses:\s*\./\.github/actions/build-kernel\s*$\n(?P<body>.*?)(?=^      - name:|\Z)",
    workflow_text,
)
if not build_step or not re.search(
    r"(?m)^          upload_final_zip:\s*false\s*$", build_step.group("body")
):
    raise SystemExit("OP13 all-variant workflow must pass upload_final_zip: false to the composite build step")
if not re.search(
    r"(?m)^          artifact_slug:\s*\$\{\{ matrix\.slug \}\}\s*$",
    build_step.group("body"),
):
    raise SystemExit("OP13 matrix workflow must pass matrix.slug as artifact_slug")
PY

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

require(
    r"(?ms)^\s{6}optimize_level:\s*$.*?^\s{8}options:\s*\[O2, O3\]\s*$",
    "workflow_dispatch optimize_level must preserve O2/O3 choices",
)

require(r"^\s{4}strategy:\s*$", "build job must declare a strategy")
require(r"^\s{6}fail-fast:\s*false\s*$", "matrix strategy must set fail-fast: false")
require(r"^\s{6}matrix:\s*$", "build job strategy must declare a matrix")
require(r"^\s{8}include:\s*$", "matrix strategy must use an include list")

include_section = text[text.index("include:") :]
row_blocks = re.findall(r"(?ms)^ {10}- slug:\s*[^\n]+.*?(?=^ {10}- slug:|\Z)", include_section)
rows = []
for block in row_blocks:
    fields = dict(re.findall(r"(?m)^ {12}([A-Za-z_]+):\s*([^\n]+)$", block))
    slug = re.match(r"^ {10}- slug:\s*([^\n]+)", block)
    fields["slug"] = slug.group(1) if slug else ""
    rows.append(tuple(fields.get(key, "") for key in ("slug", "config", "manifest", "compatibility")))
if rows != expected_rows:
    raise SystemExit(f"matrix include must equal the six approved rows; got {rows!r}")
if re.search(r"(?m)^ {12}(?:region|model):", "\n".join(row_blocks)):
    raise SystemExit("matrix rows must not invent region or model mappings")

require_text(".github/update-state/op13-upstreams.json", "workflow must retain the pinned upstream state source")
require_text(".sources.resukisu.sha", "workflow must retain the ReSukiSU state pin")
require_text(".sources.susfs.sha", "workflow must retain the SUSFS state pin")
require_text("ksu_branch_or_hash: ${{ steps.config.outputs.resukisu_sha }}", "workflow must pass the ReSukiSU state pin")
require_text("susfs_commit_hash_or_branch: ${{ steps.config.outputs.susfs_sha }}", "workflow must pass the SUSFS state pin")
require_text("op_config_json: ${{ steps.config.outputs.json }}", "workflow must pass the matrix config JSON to the build action")
require_text("artifact_slug: ${{ matrix.slug }}", "workflow must pass the unique matrix slug to debug uploads")
require_text("archive_final_zip: false", "matrix builds must upload uniquely named ZIPs directly")
require_text("release-metadata-${{ matrix.slug }}.json", "each matrix build must write slugged release metadata")
require_text("op13-release-${{ matrix.slug }}", "each matrix build must use a slugged artifact name")

for slug, _, _, _ in expected_rows:
    require_text(slug, f"workflow is missing required slug {slug}")

require(r"^\s{2}publish:\s*$", "workflow must have one publish job")
publish_start = text.index("\n  publish:\n")
build_start = text.index("\n  build:\n")
build_section = text[build_start:publish_start]
publish_section = text[publish_start:]
if "matrix:" in publish_section:
    raise SystemExit("publish must be a non-matrix job")
if re.search(r"(?m)^\s+continue-on-error:\s*", build_section + publish_section):
    raise SystemExit("build and publish must not weaken failure propagation with continue-on-error")
needs_lines = re.findall(r"(?m)^ {4}needs:\s*([^\n]+)$", text[text.index("\njobs:\n") :])
if needs_lines != ["build"] or not re.search(r"(?m)^ {4}needs:\s*build\s*$", publish_section):
    raise SystemExit("needs: build must appear exactly once and be scoped to publish")
if re.search(r"(?m)^ {4}if:\s*.*\b(?:always|failure|cancelled)\s*\(", publish_section):
    raise SystemExit("publish must rely on default all-success gating")
require_text("op13-all-r${RUN_NUMBER}-a${RUN_ATTEMPT}", "release tag must be dynamic and shared")
require_text("OnePlus 13 ReSukiSU + SUSFS builds r${RUN_NUMBER}", "release title must be dynamic and non-regional")
require_text("| Slug | Config | Manifest | Compatibility | OOS | Kernel/KMI | ReSukiSU | SUSFS | ZIP | SHA-256 |", "release body must generate the metadata table")

config_step = re.search(
    r"(?ms)^      - name:\s*Validate and read matrix configuration\s*$\n(?P<body>.*?)(?=^      - name:|\Z)",
    build_section,
)
if not config_step:
    raise SystemExit("workflow must retain the matrix state-reading step")
config_body = config_step.group("body")
for required, message in [
    ('.target.kmi', "state-reading step must extract the authoritative Global KMI"),
    ('[[ "$global_kmi" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+-android[0-9]+-[A-Za-z0-9._+-]+$ ]]', "state-reading step must validate the Global KMI"),
    ('echo "global_kmi=$global_kmi" >> "$GITHUB_OUTPUT"', "state-reading step must expose the Global KMI"),
]:
    if required not in config_body:
        raise SystemExit(message)

prefix_step = re.search(
    r"(?ms)^      - name:\s*Prefix and describe release ZIP\s*$\n(?P<body>.*?)(?=^      - name:|\Z)",
    build_section,
)
if not prefix_step:
    raise SystemExit("workflow must retain the release metadata step")
prefix_body = prefix_step.group("body")
for required, message in [
    ('GLOBAL_KMI: ${{ steps.config.outputs.global_kmi }}', "metadata step must receive the validated Global KMI through env"),
    ('kernel_kmi="$KERNEL_VERSION"', "metadata must retain build-output fallback for non-Global rows"),
    ('if [[ "$SLUG" == "oos16-op13-global-6-6-118" ]]; then', "authoritative KMI must be selected only by the exact Global slug"),
    ('kernel_kmi="$GLOBAL_KMI"', "the exact Global row must use the authoritative state KMI"),
    ('--arg kernel_kmi "$kernel_kmi"', "metadata JSON must receive the selected KMI value"),
    ('metadata="$GITHUB_WORKSPACE/release-metadata-$SLUG.json"', "validated slug must determine the metadata filename"),
]:
    if required not in prefix_body:
        raise SystemExit(message)
if "${{ matrix.slug }}" in prefix_body[prefix_body.index("        run: |") :]:
    raise SystemExit("matrix.slug must not be interpolated directly into metadata shell source")
if re.search(r"(?m)^ {12}(?:kernel_kmi|kmi):", "\n".join(row_blocks)):
    raise SystemExit("matrix rows must not invent KMI values")

download_steps = re.findall(
    r"(?ms)^      - name:\s*Download ([^\n]+)\s*$\n(?P<body>.*?)(?=^      - name:|\Z)",
    publish_section,
)
expected_slugs = [row[0] for row in expected_rows]
if [slug for slug, _ in download_steps] != expected_slugs:
    raise SystemExit("publish must have one explicitly named download step for each approved slug")
if len(re.findall(r"(?m)^        uses:\s*actions/download-artifact@v[0-9]+\s*$", publish_section)) != 6:
    raise SystemExit("publish must download exactly six release artifacts")
for slug, body in download_steps:
    if not re.search(rf"(?m)^          name:\s*op13-release-{re.escape(slug)}\s*$", body):
        raise SystemExit(f"download step must request the exact artifact for {slug}")
    if not re.search(rf"(?m)^          path:\s*release-dist/{re.escape(slug)}\s*$", body):
        raise SystemExit(f"download step must isolate the artifact directory for {slug}")

publish_step = re.search(
    r"(?ms)^      - name:\s*Validate and publish aggregate release\s*$\n(?P<body>.*?)(?=^      - name:|\Z)",
    publish_section,
)
if not publish_step:
    raise SystemExit("publish must retain a single validation-and-release step")
publish_body = publish_step.group("body")
slugs_match = re.search(r"(?ms)^          slugs=\(\s*$\n(?P<body>.*?)^          \)\s*$", publish_body)
if not slugs_match:
    raise SystemExit("publish must declare the exact expected slug inventory")
published_slugs = [line.strip() for line in slugs_match.group("body").splitlines() if line.strip()]
if published_slugs != expected_slugs:
    raise SystemExit(f"publish slug inventory must equal the matrix rows; got {published_slugs!r}")
for required, message in [
    ("find release-dist -type f -name 'release-metadata-*.json'", "publish must enumerate metadata files"),
    ("find release-dist -type f -name '*.zip'", "publish must enumerate ZIP files"),
    ('[[ "${#metadata_files[@]}" -eq 6 ]]', "publish must require exactly six metadata files"),
    ('[[ "${#zip_files[@]}" -eq 6 ]]', "publish must require exactly six ZIP files"),
    ('keys == ["compatibility", "config", "kernel_kmi", "manifest", "oos", "resukisu", "sha256", "slug", "susfs", "zip"]', "publish must require the exact metadata schema"),
    ('all(.[]; type == "string" and length > 0)', "publish must require every metadata field to be a non-empty string"),
    ('declare -A seen_zip=()', "publish must track unique ZIP basenames"),
    ('[[ -z "${seen_zip[$zip]+x}" ]]', "publish must reject duplicate ZIP basenames"),
    ('actual_sha256="$(sha256sum "$zip_path" | awk \'{print $1}\')"', "publish must recompute every downloaded ZIP SHA-256"),
    ('[[ "$actual_sha256" == "$expected_sha256" ]]', "publish must compare every recomputed ZIP SHA-256"),
    ('zip_paths+=("$zip_path")', "publish must build a validated release asset list"),
]:
    if required not in publish_body:
        raise SystemExit(message)

mapping_expectations = {
    slug: (config, manifest, compatibility, "OOS15" if slug.startswith("oos15-") else "OOS16")
    for slug, config, manifest, compatibility in expected_rows
}
for slug, expected in mapping_expectations.items():
    mapping = re.search(
        rf"(?ms)^              {re.escape(slug)}\)\s*$\n(?P<body>.*?)(?=^                ;;\s*$)",
        publish_body,
    )
    if not mapping:
        raise SystemExit(f"publish validation is missing the exact mapping branch for {slug}")
    mapping_body = mapping.group("body")
    actual = []
    for field in ("config", "manifest", "compatibility", "oos"):
        value = re.search(rf"(?m)^                expected_{field}=(?:'([^']*)'|([^\n]+))$", mapping_body)
        actual.append((value.group(1) if value and value.group(1) is not None else value.group(2).strip()) if value else None)
    if tuple(actual) != expected:
        raise SystemExit(f"publish mapping mismatch for {slug}: {tuple(actual)!r}")

sha_check = publish_body.index('[[ "$actual_sha256" == "$expected_sha256" ]]')
asset_append = publish_body.index('zip_paths+=("$zip_path")')
release_call = publish_body.index('gh release create "$tag" "${zip_paths[@]}"')
if not sha_check < asset_append < release_call:
    raise SystemExit("only SHA-validated ZIP paths may reach gh release create")
if len(re.findall(r"\bgh\s+release\s+create\b", text)) != 1:
    raise SystemExit("workflow must invoke gh release create exactly once")
if not re.search(r'(?m)^          gh release create "\$tag" "\$\{zip_paths\[@\]\}" \\$', publish_body):
    raise SystemExit("gh release create must consume only the validated ZIP path array")

print("PASS: OP13 all-variant action contract")
PY
