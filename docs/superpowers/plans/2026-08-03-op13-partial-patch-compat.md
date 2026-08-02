# OP13 Partial Patch Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the OOS15 6.6.30 SUSFS patch and OOS16 HMBIRD patch fail safely and compile without disabling ReSukiSU, SUSFS, or HMBIRD.

**Architecture:** Keep both repairs inside the existing composite build action at the boundary where each external patch is applied. Recover only the two exact, observed incompatibilities and verify the resulting source; unknown rejects remain fatal.

**Tech Stack:** GitHub composite actions, Bash, GNU `grep`/`sed`, JSON via `jq`, existing shell contract tests.

## Global Constraints

- Do not change the six retained OP13 manifests or the matrix shape.
- Keep `susfs: true` for OOS15 6.6.30 and `hmbird: true` for OOS16 OP13.
- Never touch or stage `artifacts/**`.
- Treat unknown HMBIRD rejects as fatal; do not delete diagnostic `.rej` files before validation.
- Apply production changes only after the regression test fails for the expected missing behavior.

---

### Task 1: Add RED regression coverage

**Files:**
- Modify: `tests/op13-all-action-test.sh`

**Interfaces:**
- Consumes: the `Apply SUSFS Patches` and `Apply Other Patches` step bodies in `.github/actions/build-kernel/action.yml`.
- Produces: contract failures until both narrow recovery blocks exist and preserve the feature flags.

- [ ] **Step 1: Add a SUSFS compatibility assertion**

Extract the `Apply SUSFS Patches` body and require, after the `50_add_susfs_in_gki-android15-6.6.patch` application and before `# Revert Fake kernel patch`:

```bash
grep -qF '__fold_filemap_fixup_entry' "$COMMON_KERNEL_FOLDER/include/linux/page_size_compat.h"
sed -i '/^[[:space:]]*__fold_filemap_fixup_entry(&((struct proc_maps_private \*)m->private)->iter, &end);[[:space:]]*$/d'
```

Also require a postcondition that fails if the exact call remains while its declaration is absent.

- [ ] **Step 2: Add an HMBIRD reject-recovery assertion**

Extract the `Apply Other Patches` body and require, inside the failed Fengchi patch branch and before generic reject cleanup:

```bash
grep -qF 'sched_ext_free(tsk);' kernel/fork.c.rej
grep -qF 'hmbird_free(tsk);' kernel/fork.c.rej
```

Require an exact replacement in `kernel/fork.c`, verification that `sched_ext_free(tsk);` is gone, removal of only the handled reject, and a fatal check for any remaining `.rej` file.

- [ ] **Step 3: Protect feature intent**

Assert literal JSON booleans remain enabled:

```bash
jq -e '.susfs == true' configs/oos15/OP13-6.6.30.json
jq -e '.hmbird == true' configs/oos16/OP13.json
```

- [ ] **Step 4: Verify RED**

Run:

```bash
bash tests/op13-all-action-test.sh
```

Expected: FAIL because the SUSFS capability recovery and HMBIRD rejected-hunk recovery are absent.

---

### Task 2: Implement the minimal fail-closed repairs

**Files:**
- Modify: `.github/actions/build-kernel/action.yml`
- Test: `tests/op13-all-action-test.sh`

**Interfaces:**
- Consumes: `$COMMON_KERNEL_FOLDER`, the applied SUSFS source tree, and `kernel/fork.c.rej` emitted by the Fengchi patch.
- Produces: a source tree with no undeclared compatibility calls and no silently discarded unknown rejects.

- [ ] **Step 1: Repair the unsupported SUSFS helper call**

Immediately after the SUSFS patch result is handled, check whether `fs/proc/task_mmu.c` contains the exact injected call and the page-size compatibility header lacks the matching declaration. Only in that state, delete the exact call line. Re-check and exit with an Actions error if a dangling call remains.

- [ ] **Step 2: Recover the known HMBIRD rejected hunk**

In the failed Fengchi branch, before reject dumping/deletion, require `kernel/fork.c.rej` to contain both the removed `sched_ext_free(tsk);` line and the replacement `hmbird_free(tsk);` line. Replace only the exact call in `kernel/fork.c` with:

```c
#ifdef CONFIG_HMBIRD_SCHED
    hmbird_free(tsk);
#endif
```

Verify the replacement and absence of the stale call, then remove only `kernel/fork.c.rej`. Exit non-zero if the evidence is not exact or any `.rej` remains.

- [ ] **Step 3: Verify GREEN**

Run:

```bash
bash -n tests/op13-all-action-test.sh
bash tests/op13-all-action-test.sh
for f in configs/oos15/*.json configs/oos16/*.json; do jq empty "$f"; done
for f in manifests/oos15/*.xml manifests/oos16/*.xml; do xmllint --noout "$f"; done
```

Expected: all commands succeed, exactly six tracked manifests remain, and `git diff -- artifacts` is empty.

- [ ] **Step 4: Review and publish**

Request an independent code review and Antigravity review. After findings are resolved, have the Git agent commit the scoped files, fast-forward `main`, push, run `build-op13-all.yml`, monitor all six jobs, and verify the published release assets.
