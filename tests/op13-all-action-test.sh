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
  "manifests/oos16/oneplus_13_6.6.89_w.xml"
  "manifests/oos16/oneplus_13_global_6.6.118_w.xml"
  "manifests/oos16/oneplus_13_w.xml"
  "manifests/oos16/oneplus_13t_6.6.89_w.xml"
  "manifests/oos16/oneplus_ace3_pro_6.1.118_w.xml"
  "manifests/oos16/oneplus_ace5_pro_6.6.89_w.xml"
  "manifests/oos16/oneplus_n6_w.xml"
  "manifests/oos16/oneplus_nord_3_w.xml"
  "manifests/oos16/oneplus_turbo_6v_6.1.118_w.xml"
  "manifests/oos16/oneplus_turbo_6x_w.xml"
)
expected_configs=(
  "configs/oos15/OP13-6.6.30.json"
  "configs/oos15/OP13-CPH-6.6.56.json"
  "configs/oos15/OP13-CPH.json"
  "configs/oos15/OP13-PJZ.json"
  "configs/oos16/OP13-6.6.89.json"
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
  fail "tracked manifest inventory must be exactly the approved fourteen files"

mapfile -t actual_op13_configs < <(
  git -C "$repo_root" ls-files 'configs/oos15/*.json' 'configs/oos16/*.json' |
    awk -F/ '$3 ~ /^OP13(-.*)?\.json$/ { print }' | sort
)
expected_config_list=$(printf '%s\n' "${expected_configs[@]}")
actual_op13_config_list=$(printf '%s\n' "${actual_op13_configs[@]}")
[[ "$actual_op13_config_list" == "$expected_config_list" ]] ||
  fail "tracked base OP13 config inventory must be exactly the approved seven files"

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
    for boolean_field in ("opt", "bbr3", "ds"):
        if not isinstance(config.get(boolean_field), bool):
            raise SystemExit(f"{config_path}: {boolean_field} must be a JSON boolean")
    if config.get("ds") is not True:
        raise SystemExit(f"{config_path}: approved OP13 config must enable Droidspaces")
    if config.get("ds_userns_mode") != "hardened":
        raise SystemExit(f"{config_path}: release builds must select hardened Droidspaces USER_NS policy explicitly")
    if config.get("opt") is not True:
        raise SystemExit(f"{config_path}: approved OP13 configs must enable optimization patches")
    if config_path == "configs/oos16/OP13-GLOBAL-6.6.118.json" and config.get("custom_patches") is not True:
        raise SystemExit(f"{config_path}: Global 6.6.118 validation must apply the optimization patch bundle")
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
    ('for boolean_field in opt bbr3; do', "opt and bbr3 must be checked as required JSON booleans"),
    ('has($field) and (.[$field] | type) == "boolean"', "opt and bbr3 must use a boolean JSON type predicate"),
    ('(.ds_userns_mode | type) == "string"', "Droidspaces USER_NS mode must be type-checked before export"),
    ('echo "OP_DS_USERNS_MODE=hardened" >> "$GITHUB_ENV"', "missing Droidspaces USER_NS mode must default to hardened"),
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
    ('bbr3="$OP_BBR3"', "bbr3 must be assigned for validation"),
    ("Input 'bbr3' contains invalid characters. Allowed: 'true' or 'false'. Got: '$bbr3'", "bbr3 must have boolean-only validation"),
    ('opt="$OP_OPT"', "opt must be assigned for validation"),
    ("Input 'opt' contains invalid characters. Allowed: 'true' or 'false'. Got: '$opt'", "opt must have boolean-only validation"),
    ('ds_userns_mode="${OP_DS_USERNS_MODE:-hardened}"', "Droidspaces USER_NS mode must default safely during validation"),
    ("Input 'ds_userns_mode' must be 'hardened' or 'compat'. Got: '$ds_userns_mode'", "Droidspaces USER_NS mode must reject unsupported policies"),
    ('custom_patches=false cannot be combined with opt=true or hmbird=true', "disabled custom patches must not leave opt or hmbird as false-positive flags"),
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
fold_decl = "extern void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end);"
fold_decl_check = f"grep -qxF '{fold_decl}' ./include/linux/page_size_compat.h"
fold_backport = 'patch -p1 --forward < "$KERNEL_PATCHES_FOLDER/common/backports/fold_fixup_entries.patch"'
susfs_revert_marker = "# Revert Fake kernel patch"
susfs_patch_idx = susfs_body.find(susfs_patch)
fold_decl_idx = susfs_body.find(fold_decl_check)
fold_backport_idx = susfs_body.find(fold_backport)
susfs_revert_idx = susfs_body.find(susfs_revert_marker)
if min(susfs_patch_idx, fold_decl_idx, fold_backport_idx, susfs_revert_idx) == -1:
    raise SystemExit("SUSFS android15-6.6 compatibility must backport __fold_filemap_fixup_entry when its declaration is missing")
if not fold_decl_idx < fold_backport_idx < susfs_patch_idx < susfs_revert_idx:
    raise SystemExit("the fold-fixup backport must run before the main SUSFS patch and compatibility postconditions")
fold_backport_region = susfs_body[fold_decl_idx:susfs_patch_idx]
for required, message in [
    ("::error::fold_fixup_entries backport failed", "fold-fixup backport failure must emit an actionable error"),
    ('find . -name "*.rej"', "fold-fixup backport failure must dump reject diagnostics"),
    ("exit 1", "fold-fixup backport failure must stop the build"),
]:
    if required not in fold_backport_region:
        raise SystemExit(message)

susfs_compat_region = susfs_body[susfs_patch_idx:susfs_revert_idx]
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
if re.search(r"(?m)^\s*sed\s+-i\s+.*__fold_filemap_fixup_entry.*(?:\./)?fs/proc/task_mmu\.c", susfs_body):
    raise SystemExit("SUSFS compatibility must preserve the fold-fixup call instead of deleting it")

nameidata_legacy_signature = "static void set_nameidata\\(struct nameidata \\*p, int dfd, struct filename \\*name\\)"
nameidata_old_call = "old_set_nameidata_call='set_nameidata(nd, old_dfd, fake_filename, NULL);'"
nameidata_new_call = "new_set_nameidata_call='set_nameidata(nd, old_dfd, fake_filename);'"
vma_probe = "if grep -q 'VMA_PAD_START(' ./fs/proc/task_mmu.c && ! grep -qE '#include <linux/pgsize_migration(_inline)?\\.h>|define VMA_PAD_START' ./fs/proc/task_mmu.c; then"
vma_anchor = "grep -qF '#include \"internal.h\"' ./fs/proc/task_mmu.c"
vma_fallback = "#define VMA_PAD_START(vma) ((vma)->vm_end)"
for required, message in [
    (nameidata_legacy_signature, "SUSFS recovery must identify the legacy three-argument set_nameidata API"),
    (nameidata_old_call, "SUSFS recovery must match the incompatible four-argument set_nameidata call"),
    (nameidata_new_call, "SUSFS recovery must replace the incompatible set_nameidata call with its three-argument form"),
    (vma_probe, "SUSFS recovery must detect a missing page-size-migration VMA_PAD_START provider"),
    (vma_anchor, "SUSFS recovery must anchor the compatibility definition after internal.h"),
    (vma_fallback, "SUSFS recovery must provide the WildKernels VMA_PAD_START fallback"),
]:
    if required not in susfs_body:
        raise SystemExit(message)
if not susfs_patch_idx < susfs_body.find(nameidata_old_call) < susfs_revert_idx:
    raise SystemExit("set_nameidata compatibility recovery must run after the SUSFS patch attempt and before fake-patch rollback")
if not susfs_patch_idx < susfs_body.find(vma_fallback) < susfs_revert_idx:
    raise SystemExit("VMA padding fallback must run after the SUSFS patch attempt and before fake-patch rollback")
if "s|VMA_PAD_START(vma)|vma->vm_end|g" in susfs_body:
    raise SystemExit("SUSFS compatibility must preserve VMA_PAD_START call sites and provide a fallback definition")

ccache_step = re.search(
    r"(?ms)^    - name:\s*Check and Prepare Caches\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not ccache_step:
    raise SystemExit("build action must retain the Check and Prepare Caches step")
ccache_body = ccache_step.group("body")
if 'ccache --set-config=extra_files_to_hash=""' not in ccache_body:
    raise SystemExit("ccache setup must reset extra_files_to_hash for every run before overlay can override it")

ccache_restore = re.search(
    r"(?ms)^    - name:\s*Restore ccache cache\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
ccache_save = re.search(
    r"(?ms)^    - name:\s*Save ccache cache\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
ccache_prune = re.search(
    r"(?ms)^    - name:\s*Prune ccache before saving\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not all((ccache_restore, ccache_save, ccache_prune)):
    raise SystemExit("ccache must retain restore, prune, and save steps")
if "uses: actions/cache/restore@v4" not in ccache_restore.group("body"):
    raise SystemExit("ccache restore must use GitHub Actions cache")
if "uses: actions/cache/save@v4" not in ccache_save.group("body"):
    raise SystemExit("ccache save must use GitHub Actions cache")
if "continue-on-error: true" not in ccache_save.group("body"):
    raise SystemExit("ccache upload failure must not fail a completed kernel build")
if "ccache --cleanup" not in ccache_prune.group("body"):
    raise SystemExit("ccache must be pruned to its configured size before saving")
if 'cache_bucket: "ccache-cache"' in ccache_restore.group("body") or 'cache_bucket: "ccache-cache"' in ccache_save.group("body"):
    raise SystemExit("ccache must not use the legacy Release cache bucket")
if "CCACHE_MAXSIZE: 5G" not in workflow_text:
    raise SystemExit("OP13 workflow must cap ccache at 5G")

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
for required, message in [
    ("if: ${{ env.OP_CUSTOM_PATCHES == 'true' && (env.OP_OPT == 'true' || env.OP_HMBIRD == 'true') }}", "Other Patches must run only for explicitly enabled optimization or HMBIRD work"),
    ('if [ "$OP_OPT" != true ]; then', "HMBIRD-only builds must stop before applying the optimization bundle"),
    ('if [ "$OP_BBR" = "false" ] && [ "$OP_BBR3" = "false" ]; then', "force_tcp_nodelay must be gated off for both BBR implementations"),
    ('Skipping force_tcp_nodelay.patch because BBR or BBRv3 is enabled', "BBR conflict skip must be visible in build logs"),
]:
    if required not in apply_other_body:
        raise SystemExit(message)
force_tcp_idx = apply_other_body.find('patch -p1 --forward < "$KERNEL_PATCHES_FOLDER/common/force_tcp_nodelay.patch"')
force_tcp_guard_idx = apply_other_body.find('if [ "$OP_BBR" = "false" ] && [ "$OP_BBR3" = "false" ]; then')
if min(force_tcp_idx, force_tcp_guard_idx) == -1 or not force_tcp_guard_idx < force_tcp_idx:
    raise SystemExit("force_tcp_nodelay must be applied only inside the BBR/BBRv3-disabled guard")
fengchi_failure = re.search(
    r"(?ms)if ! patch -p1 --fuzz=2 < \"\$FENGCHI_DIR/fengchi_\$\{HMBIRD_MODEL\}_\$\{HMBIRD_OS\}\.patch\"; then\s*$\n(?P<body>.*?)(?=^          fi\s*$)",
    apply_other_body,
)
if not fengchi_failure:
    raise SystemExit("Apply Other Patches must retain the failed Fengchi patch branch")
fengchi_failure_body = fengchi_failure.group("body")
handled_init_idx = fengchi_failure_body.find("handled_fengchi_rejects=0")
legacy_required_fork_idx = fengchi_failure_body.find("if [ ! -f kernel/fork.c.rej ]; then")
if legacy_required_fork_idx != -1:
    raise SystemExit("HMBIRD Fengchi recovery must not require kernel/fork.c.rej when another known reject is recoverable")
fork_handler_idx = fengchi_failure_body.find("if [ -f kernel/fork.c.rej ]; then")
reject_hunk_count_idx = fengchi_failure_body.find(
    "reject_hunk_count=$(awk '/^@@ / { count++ } END { print count + 0 }' kernel/fork.c.rej)"
)
reject_hunk_count_failure = re.search(
    r"(?ms)if\s+\[\s+\"\$reject_hunk_count\"\s+-ne\s+1\s+\];\s*then\s*$"
    r"(?P<body>.*?)(?=^\s*fi\s*$)",
    fengchi_failure_body,
)
reject_hunk_count_failure_idx = reject_hunk_count_failure.start() if reject_hunk_count_failure else -1
old_reject_idx = fengchi_failure_body.find("grep -qF 'sched_ext_free(tsk);' kernel/fork.c.rej")
new_reject_idx = fengchi_failure_body.find("grep -qF 'hmbird_free(tsk);' kernel/fork.c.rej")
old_hook_count_idx = fengchi_failure_body.find(
    "old_fork_hook_count=$(awk '/^[[:space:]]*sched_ext_free\\(tsk\\);$/ { count++ } END { print count + 0 }' kernel/fork.c)"
)
old_hook_count_failure_idx = fengchi_failure_body.find('[ "$old_fork_hook_count" -ne 1 ]')
direct_transform_idx = fengchi_failure_body.find(
    "perl -i -0pe 's/^[[:blank:]]*sched_ext_free\\(tsk\\);\\n/#ifdef CONFIG_HMBIRD_SCHED\\n    hmbird_free(tsk);\\n#endif\\n/m' kernel/fork.c"
)
exact_block_match = re.search(
    re.escape("grep -zqF $'#ifdef CONFIG_HMBIRD_SCHED\\n    hmbird_free(tsk);\\n#endif' kernel/fork.c") + r"(?:\s|$)",
    fengchi_failure_body,
)
exact_block_idx = exact_block_match.start() if exact_block_match else -1
old_hook_idx = (
    fengchi_failure_body.find("grep -qE '^[[:space:]]*sched_ext_free\\(tsk\\);$' kernel/fork.c", exact_block_idx)
    if exact_block_idx != -1
    else -1
)
handled_reject_idx = fengchi_failure_body.find("rm -f kernel/fork.c.rej")
handled_fork_idx = (
    fengchi_failure_body.find("handled_fengchi_rejects=$((handled_fengchi_rejects + 1))", handled_reject_idx)
    if handled_reject_idx != -1
    else -1
)
cpufreq_handler_idx = fengchi_failure_body.find("if [ -f include/linux/cpufreq.h.rej ]; then")
cpufreq_hunk_count_idx = fengchi_failure_body.find(
    "cpufreq_reject_hunk_count=$(awk '/^@@ / { count++ } END { print count + 0 }' include/linux/cpufreq.h.rej)"
)
cpufreq_hunk_count_failure = re.search(
    r"(?ms)if\s+\[\s+\"\$cpufreq_reject_hunk_count\"\s+-ne\s+1\s+\];\s*then\s*$"
    r"(?P<body>.*?)(?=^\s*fi\s*$)",
    fengchi_failure_body,
)
cpufreq_hunk_count_failure_idx = cpufreq_hunk_count_failure.start() if cpufreq_hunk_count_failure else -1
cpufreq_reject_decl_count_idx = fengchi_failure_body.find(
    "cpufreq_reject_decl_count=$(perl -0ne 'BEGIN { $block = \"+ssize_t store_scaling_governor(struct cpufreq_policy *policy,\\n+                                        const char *buf, size_t count);\\n+ssize_t show_scaling_governor(struct cpufreq_policy *policy, char *buf);\"; } $count = () = /\\Q$block\\E/g; print \"$count\\n\";' include/linux/cpufreq.h.rej)"
)
cpufreq_added_count_idx = fengchi_failure_body.find(
    "cpufreq_added_hunk_count=$(awk '/^@@ / { in_hunk=1; next } in_hunk && /^[+]/ { count++ } END { print count + 0 }' include/linux/cpufreq.h.rej)"
)
cpufreq_added_failure_idx = fengchi_failure_body.find('[ "$cpufreq_added_hunk_count" -ne 4 ]')
cpufreq_added_error_idx = fengchi_failure_body.find("exactly four added lines")
cpufreq_blank_added_count_idx = fengchi_failure_body.find(
    "cpufreq_blank_added_hunk_count=$(awk '/^@@ / { in_hunk=1; next } in_hunk && /^\\+$/ { count++ } END { print count + 0 }' include/linux/cpufreq.h.rej)"
)
cpufreq_blank_added_failure_idx = fengchi_failure_body.find('[ "$cpufreq_blank_added_hunk_count" -ne 1 ]')
cpufreq_blank_added_error_idx = fengchi_failure_body.find("exactly one blank added line")
cpufreq_removed_count_idx = fengchi_failure_body.find(
    "cpufreq_removed_hunk_count=$(awk '/^@@ / { in_hunk=1; next } in_hunk && /^-/ { count++ } END { print count + 0 }' include/linux/cpufreq.h.rej)"
)
cpufreq_removed_failure_idx = fengchi_failure_body.find('[ "$cpufreq_removed_hunk_count" -ne 0 ]')
cpufreq_target_exists_idx = fengchi_failure_body.find("if [ ! -f include/linux/cpufreq.h ]; then")
cpufreq_target_decl_count_idx = fengchi_failure_body.find(
    "cpufreq_target_decl_count=$(perl -0ne 'BEGIN { $block = \"ssize_t store_scaling_governor(struct cpufreq_policy *policy,\\n                                        const char *buf, size_t count);\\nssize_t show_scaling_governor(struct cpufreq_policy *policy, char *buf);\"; } $count = () = /\\Q$block\\E/g; print \"$count\\n\";' include/linux/cpufreq.h)"
)
cpufreq_context_idx = fengchi_failure_body.find(
    "cpufreq_expected_context=$'enum cpufreq_table_sorting {\\n\\tCPUFREQ_TABLE_UNSORTED,\\n\\tCPUFREQ_TABLE_SORTED_ASCENDING,\\n\\tCPUFREQ_TABLE_SORTED_DESCENDING,\\n};\\n\\nssize_t store_scaling_governor(struct cpufreq_policy *policy,\\n                                        const char *buf, size_t count);\\nssize_t show_scaling_governor(struct cpufreq_policy *policy, char *buf);\\n\\nstruct cpufreq_cpuinfo {'"
)
cpufreq_context_check_idx = fengchi_failure_body.find(
    'grep -zqF "$cpufreq_expected_context" include/linux/cpufreq.h'
)
cpufreq_cleanup_idx = fengchi_failure_body.find("rm -f include/linux/cpufreq.h.rej")
handled_cpufreq_idx = (
    fengchi_failure_body.find("handled_fengchi_rejects=$((handled_fengchi_rejects + 1))", cpufreq_cleanup_idx)
    if cpufreq_cleanup_idx != -1
    else -1
)
no_known_reject_match = re.search(
    r"(?ms)if\s+\[\s+\"\$handled_fengchi_rejects\"\s+-eq\s+0\s+\];\s*then\s*$"
    r"(?P<body>.*?)(?=^\s*fi\s*$)",
    fengchi_failure_body,
)
no_known_reject_idx = no_known_reject_match.start() if no_known_reject_match else -1
remaining_reject_match = re.search(
    r"(?ms)if\s+\[\s+-n\s+\"\$\(find \. -name '\*\.rej' -print -quit\)\"\s+\];\s*then\s*$"
    r"(?P<body>.*?)(?=^\s*fi\s*$)",
    fengchi_failure_body,
)
remaining_reject_idx = remaining_reject_match.start() if remaining_reject_match else -1
ordered_hmbird_indexes = [
    handled_init_idx,
    fork_handler_idx,
    reject_hunk_count_idx,
    reject_hunk_count_failure_idx,
    old_reject_idx,
    new_reject_idx,
    old_hook_count_idx,
    old_hook_count_failure_idx,
    direct_transform_idx,
    exact_block_idx,
    old_hook_idx,
    handled_reject_idx,
    handled_fork_idx,
    cpufreq_handler_idx,
    cpufreq_hunk_count_idx,
    cpufreq_hunk_count_failure_idx,
    cpufreq_reject_decl_count_idx,
    cpufreq_added_count_idx,
    cpufreq_added_failure_idx,
    cpufreq_added_error_idx,
    cpufreq_blank_added_count_idx,
    cpufreq_blank_added_failure_idx,
    cpufreq_blank_added_error_idx,
    cpufreq_removed_count_idx,
    cpufreq_removed_failure_idx,
    cpufreq_target_exists_idx,
    cpufreq_target_decl_count_idx,
    cpufreq_context_idx,
    cpufreq_context_check_idx,
    cpufreq_cleanup_idx,
    handled_cpufreq_idx,
    no_known_reject_idx,
    remaining_reject_idx,
]
if min(ordered_hmbird_indexes) == -1:
    raise SystemExit("HMBIRD Fengchi recovery must count handled rejects, preserve optional fork recovery, prove exact optional cpufreq already-applied evidence, and keep the final remaining-reject failure")
if ordered_hmbird_indexes != sorted(ordered_hmbird_indexes) or len(set(ordered_hmbird_indexes)) != len(ordered_hmbird_indexes):
    raise SystemExit("HMBIRD Fengchi recovery checks must run in strict handled-count, fork recovery, cpufreq evidence, no-known-reject, remaining-reject order")
if not reject_hunk_count_failure:
    raise SystemExit("HMBIRD Fengchi recovery must fail closed unless kernel/fork.c.rej has exactly one unified hunk")
reject_hunk_count_failure_body = reject_hunk_count_failure.group("body")
for required, message in [
    ("::error::", "unexpected HMBIRD reject hunk count must emit ::error::"),
    ("find . -name", "unexpected HMBIRD reject hunk count must dump reject diagnostics"),
    ("exit 1", "unexpected HMBIRD reject hunk count must exit non-zero"),
]:
    if required not in reject_hunk_count_failure_body:
        raise SystemExit(message)
if not cpufreq_hunk_count_failure:
    raise SystemExit("HMBIRD Fengchi cpufreq recovery must fail closed unless include/linux/cpufreq.h.rej has exactly one unified hunk")
cpufreq_hunk_count_failure_body = cpufreq_hunk_count_failure.group("body")
for required, message in [
    ("::error::", "unexpected HMBIRD cpufreq reject hunk count must emit ::error::"),
    ("find . -name", "unexpected HMBIRD cpufreq reject hunk count must dump reject diagnostics"),
    ("exit 1", "unexpected HMBIRD cpufreq reject hunk count must exit non-zero"),
]:
    if required not in cpufreq_hunk_count_failure_body:
        raise SystemExit(message)
if not no_known_reject_match:
    raise SystemExit("HMBIRD Fengchi recovery must fail when patch exits nonzero but no known reject was handled")
no_known_reject_body = no_known_reject_match.group("body")
for required, message in [
    ("::error::", "missing-known-reject path must emit ::error::"),
    ("find . -name", "missing-known-reject path must dump reject diagnostics"),
    ("exit 1", "missing-known-reject path must exit non-zero"),
]:
    if required not in no_known_reject_body:
        raise SystemExit(message)
cpufreq_region = (
    fengchi_failure_body[cpufreq_handler_idx:cpufreq_cleanup_idx]
    if cpufreq_handler_idx != -1 and cpufreq_cleanup_idx != -1
    else ""
)
if re.search(r"\b(?:sed|perl)\s+-i\b.*include/linux/cpufreq\.h(?:\s|$)", cpufreq_region):
    raise SystemExit("HMBIRD Fengchi cpufreq recovery must not mutate include/linux/cpufreq.h")
if "sed -i 's/sched_ext_free(tsk);/hmbird_free(tsk);/' kernel/fork.c" in fengchi_failure_body:
    raise SystemExit("HMBIRD Fengchi recovery must not use an unanchored sed replacement for the fork hook")
if "s/^[[:blank:]]*hmbird_free\\(tsk\\);" in fengchi_failure_body:
    raise SystemExit("HMBIRD Fengchi recovery must not create hmbird_free first and wrap a later matching token")
if re.search(re.escape("grep -qF 'hmbird_free(tsk);' kernel/fork.c") + r"(?:\s|$)", fengchi_failure_body):
    raise SystemExit("HMBIRD Fengchi recovery must verify the exact guarded hmbird_free block, not an independent token")
if re.search(re.escape("grep -qF '#ifdef CONFIG_HMBIRD_SCHED' kernel/fork.c") + r"(?:\s|$)", fengchi_failure_body):
    raise SystemExit("HMBIRD Fengchi recovery must verify the exact guarded hmbird_free block, not an independent guard token")
if re.search(r"find \. -name ['\"]\*\.rej['\"] -delete", fengchi_failure_body):
    raise SystemExit("HMBIRD Fengchi recovery must not delete all reject files generically")
masked_reject_cleanup = re.search(
    r"(?m)^\s*(?:find \. -name ['\"]\*\.rej['\"].*|rm\s+(?:-[A-Za-z]+\s+)*[^;\n]*\.rej\b.*)\|\|\s*true\b",
    fengchi_failure_body,
)
if masked_reject_cleanup:
    raise SystemExit("HMBIRD Fengchi recovery must not mask reject/file cleanup with || true")
remaining_reject_region = fengchi_failure_body[handled_reject_idx:]
if re.search(r"find \. -name ['\"]\*\.rej['\"] -delete", remaining_reject_region):
    raise SystemExit("HMBIRD Fengchi recovery remaining-reject region must not mask failures or delete rejects generically")
if not remaining_reject_match or "exit 1" not in remaining_reject_match.group("body"):
    raise SystemExit("HMBIRD Fengchi recovery must use find . -name '*.rej' -print -quit and fail if any unhandled reject files remain")

bbr3_step = re.search(
    r"(?ms)^    - name:\s*Apply BBRv3\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not bbr3_step:
    raise SystemExit("build action must have a dedicated BBRv3 step")
bbr3_body = bbr3_step.group("body")
for required, message in [
    ("if: ${{ env.OP_BBR3 == 'true' }}", "BBRv3 step must be gated by OP_BBR3"),
    ('0001-net-tcp-backport-BBRv3-to-${ANDROID_VER}-${KERNEL_VER}.patch', "BBRv3 must select the upstream patch by Android and kernel version"),
    ('[ ! -f "$bbr3_patch" ]', "BBRv3 must fail when no matching upstream patch exists"),
    ('CONFIG_TCP_CONG_BBR3=y', "BBRv3 must request its kernel config symbol"),
    ('patch -p1 --forward < "$bbr3_patch"', "BBRv3 must apply the selected upstream patch"),
    ('::error::BBRv3 patch failed', "BBRv3 patch failure must be actionable"),
]:
    if required not in bbr3_body:
        raise SystemExit(message)

unicode_step = re.search(
    r"(?ms)^    - name:\s*Apply Unicode Fix Patch\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not unicode_step or "Check if the decomposition result is empty" not in unicode_step.group("body"):
    raise SystemExit("Unicode flag must verify that the source-level fix marker is present")

bbg_step = re.search(
    r"(?ms)^    - name:\s*Add BBG\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not bbg_step or "if ! wget -O-" not in bbg_step.group("body") or "::error::BBG was requested" not in bbg_step.group("body"):
    raise SystemExit("BBG setup failure must fail closed instead of leaving a false-positive flag")

droidspaces_step = re.search(
    r"(?ms)^    - name:\s*Add Droidspaces support\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    action_text,
)
if not droidspaces_step:
    raise SystemExit("build action must retain the Droidspaces step")
droidspaces_body = droidspaces_step.group("body")
for required, message in [
    ('case "$OP_DS_USERNS_MODE" in', "Droidspaces must select an explicit USER_NS policy"),
    ("hardened)", "Droidspaces must support the hardened release policy"),
    ("compat)", "Droidspaces must support an opt-in application-compatible policy"),
    ('0001-Guard-USER_NS-for-non-root-users.patch', "Droidspaces hardened mode must retain the capability guard"),
    ('if(!ns_capable(current_user_ns(), CAP_SYS_ADMIN))', "both Droidspaces modes must verify the effective USER_NS guard state"),
    ('::error::Unsupported Droidspaces USER_NS mode', "Droidspaces must fail closed for unknown policies"),
]:
    if required not in droidspaces_body:
        raise SystemExit(message)

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
require_text(".sources.resukisu.ref", "workflow must retain the ReSukiSU CI branch")
require_text(".sources.resukisu.sha", "workflow must retain the ReSukiSU state pin")
require_text(".sources.susfs.sha", "workflow must retain the SUSFS state pin")
require_text("resukisu_ref=\"$(jq -er '.sources.resukisu.ref' \"$state\")\"", "workflow must read the ReSukiSU CI branch")
require_text("[[ \"$resukisu_ref\" == \"main\" ]]", "workflow must require the ReSukiSU CI/Beta branch")
require_text("ksu_branch_or_hash: ${{ steps.config.outputs.resukisu_ref }}", "workflow must resolve ReSukiSU CI immediately before the build")
require_text("RESUKISU_SHA: ${{ steps.build.outputs.ksu_commit_sha }}", "release metadata must use the resolved ReSukiSU commit")
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

python3 - "$build_action" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
build_step = re.search(
    r"(?ms)^    - name:\s*Build Kernel\s*$\n(?P<body>.*?)(?=^    - name:|\Z)",
    text,
)
if not build_step:
    raise SystemExit("build action must retain the Build Kernel step")

body = build_step.group("body")
config_generation = 'make LD="$COMMON_KERNEL_FOLDER/ld-wrapper" HOSTLD="$COMMON_KERNEL_FOLDER/ld-wrapper" O="$OUT" gki_defconfig'
namespace_config_decl = "required_namespace_configs=(\n            NAMESPACES\n            PID_NS\n            UTS_NS\n            IPC_NS\n            SYSVIPC\n            POSIX_MQUEUE\n            USER_NS\n          )"
namespace_config_loop = 'scripts/config --file "$OUT/.config" -e "$required_config"'
olddefconfig = (
    'make LD="$COMMON_KERNEL_FOLDER/ld-wrapper" '
    'HOSTLD="$COMMON_KERNEL_FOLDER/ld-wrapper" O="$OUT" olddefconfig'
)
assertion = 'grep -qx "CONFIG_${required_config}=y" "$OUT/.config" || {'
feature_helper = "require_config_enabled() {"

for required, message in [
    (namespace_config_decl, "Build Kernel must declare the full Droidspaces namespace config set"),
    (namespace_config_loop, "Build Kernel must force every required namespace config before olddefconfig"),
    ('required_namespace_configs=(USER_NS)', "Build Kernel must keep USER_NS as the non-Droidspaces fallback"),
    (assertion, "Build Kernel must assert every required namespace config after olddefconfig"),
    (feature_helper, "Build Kernel must define a reusable final-config feature assertion"),
    ('require_config_enabled KSU "KernelSU"', "Build Kernel must always verify that KernelSU survived olddefconfig"),
    ('require_config_enabled KSU_SUSFS "SUSFS"', "Build Kernel must verify an enabled SUSFS flag"),
    ('CONFIG_KSU_SUSFS_SUS_SU=y', "ReSukiSU builds must enable SUSFS process-state helpers"),
    ('require_config_enabled KSU_SUSFS_SUS_SU "ReSukiSU SUSFS process state"', "Build Kernel must verify ReSukiSU SUSFS process-state helpers"),
    ('require_config_enabled BBG "BBG"', "Build Kernel must verify an enabled BBG flag"),
    ('require_config_enabled TCP_CONG_BBR "BBR"', "Build Kernel must verify an enabled BBR flag"),
    ('require_config_enabled TCP_CONG_BBR3 "BBRv3"', "Build Kernel must verify an enabled BBRv3 flag"),
    ('require_config_enabled IP_NF_TARGET_TTL "TTL target"', "Build Kernel must verify an enabled TTL flag"),
    ('require_config_enabled IP_SET "IP set"', "Build Kernel must verify an enabled IP set flag"),
    ('require_config_enabled IP6_NF_NAT "IPv6 NAT"', "Build Kernel must verify IPv6 NAT together with IP set"),
    ('require_config_enabled NTSYNC "NTSync"', "Build Kernel must verify an enabled NTSync flag"),
    ('require_config_enabled HMBIRD_SCHED "HMBIRD"', "Build Kernel must verify an enabled HMBIRD flag"),
    ('require_config_enabled CC_OPTIMIZE_FOR_PERFORMANCE "optimization patches"', "Build Kernel must verify a supported optimization config"),
]:
    if required not in body:
        raise SystemExit(message)

config_generation_index = body.index(config_generation)
namespace_decl_index = body.index(namespace_config_decl)
enable_index = body.index(namespace_config_loop)
olddefconfig_index = body.index(olddefconfig)
assertion_index = body.index(assertion)
feature_helper_index = body.index(feature_helper)
if not config_generation_index < namespace_decl_index < enable_index < olddefconfig_index:
    raise SystemExit("Droidspaces namespace configs must be selected after gki_defconfig and before olddefconfig")
resukisu_sus_su_config = (
    'if [ "${{ inputs.ksu_type }}" = "ReSukiSU" ]; then\n'
    '          cat >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig" <<EOF\n'
    '        CONFIG_KSU_SUSFS_SUS_SU=y\n'
    '        EOF\n'
    '        fi'
)
if resukisu_sus_su_config not in body:
    raise SystemExit("ReSukiSU builds must enable SUSFS process-state helpers only for ReSukiSU")

if olddefconfig_index + len(olddefconfig) != body.rfind("for required_config in", 0, assertion_index) - len("\n        "):
    raise SystemExit("Droidspaces namespace assertions must immediately follow olddefconfig")
if not assertion_index < feature_helper_index:
    raise SystemExit("feature flags must be verified only after olddefconfig and namespace checks")
if "CONFIG_OPTIMIZE_INLINING" in body:
    raise SystemExit("Build Kernel must not require or synthesize unsupported CONFIG_OPTIMIZE_INLINING")
PY
