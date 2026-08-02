# OnePlus 13 Manifest Matrix Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single Global OOS16 workflow with an exact six-variant build matrix, retain only the six approved XML manifests, and create one release that verifies and publishes all six uniquely named ZIPs.

**Architecture:** `tests/op13-all-action-test.sh` becomes the executable acceptance contract for the approved inventory and workflow rules. `.github/workflows/build-op13-all.yml` runs one matrix build per exact config/manifest pair. Each build produces isolated runtime metadata and one uniquely named artifact; one non-matrix `publish` job verifies all six and makes one GitHub release.

**Tech Stack:** Bash; GitHub Actions YAML; XML; JSON; `jq`; `xmllint`; GitHub CLI (`gh`); Git.

## Global Constraints

- The whitelist is exactly six XML manifests and exactly six checked-in config JSON files; do not introduce variants or infer missing device/region mappings.
- Never alter `artifacts/**`.
- Preserve existing state pins and `workflow_dispatch` inputs.
- The composite build action may add only the optional `upload_final_zip` input,
  defaulting to `true`, and optional `artifact_slug`, defaulting to empty. Guard
  the final-ZIP upload with `upload_final_zip`; validate every non-empty slug and
  suffix debug names while preserving exact legacy names when empty.
  This is the backward-compatible regression contract: all existing callers
  retain their current upload behavior; only this OP13 matrix caller passes
  `false` to avoid an upload-artifact collision.
- There is one non-matrix release job, one release tag/title, and one `gh release create`; do not use a fixed `Global` release title.

---

## Interfaces

### Matrix include contract

Each matrix entry carries `slug`, `config`, `manifest`, `compatibility`, and its known OOS/kernel/KMI/ReSukiSU/SUSFS fields. The exact ordered variants are:

| slug | config | manifest | compatibility |
| --- | --- | --- | --- |
| `oos15-op13-6.6.30` | `configs/oos15/OP13-6.6.30.json` | `manifests/oos15/oneplus_13_6.6.30_v.xml` | `manifest-specific; no region inferred` |
| `oos15-op13-cph-6.6.56` | `configs/oos15/OP13-CPH-6.6.56.json` | `manifests/oos15/oneplus_13_global_6.6.56_v.xml` | `CPH2649 IN, CPH2653 EU/GLO, CPH2655 NA/US` |
| `oos15-op13-cph` | `configs/oos15/OP13-CPH.json` | `manifests/oos15/oneplus_13_global_v.xml` | `CPH2649 IN, CPH2653 EU/GLO, CPH2655 NA/US` |
| `oos15-op13-pjz` | `configs/oos15/OP13-PJZ.json` | `manifests/oos15/oneplus_13_v.xml` | `PJZ110 CN` |
| `oos16-op13-global-6.6.118` | `configs/oos16/OP13-GLOBAL-6.6.118.json` | `manifests/oos16/oneplus_13_global_6.6.118_w.xml` | `CPH2649 IN, CPH2653 EU/GLO, CPH2655 NA/US` |
| `oos16-op13` | `configs/oos16/OP13.json` | `manifests/oos16/oneplus_13_w.xml` | `manifest-specific; no region inferred` |

Do not infer a regional mapping for `configs/oos15/OP13-6.6.30.json` or `configs/oos16/OP13.json`.

### Runtime release metadata

For every matrix build, write `release-metadata-<slug>.json` beside the produced ZIP. The JSON and release-table rows must contain `slug`, exact `config`, exact `manifest`, `compatibility`, `oos`, `kernel_kmi` when known, `resukisu`, `susfs`, `zip`, and `sha256`.
Use validated state `.target.kmi` only for `oos16-op13-global-6-6-118` and
retain the build action's kernel-version output as the fallback for other rows.

## Files

- Modify/rename: `tests/op13-global-oos16-6.6.118-action-test.sh` → `tests/op13-all-action-test.sh`.
- Delete: `.github/workflows/build-op13-global-oos16-6.6.118.yml`.
- Create: `.github/workflows/build-op13-all.yml`.
- Modify: `.github/actions/build-kernel/action.yml` to add optional
  `upload_final_zip` (default `true`) and `artifact_slug` (default empty), guard
  its final-ZIP upload, make debug artifact names slug-aware, and separate the
  JSON `module_overlay` flag from `custom_patches`.
- Keep only: `manifests/oos15/oneplus_13_6.6.30_v.xml`, `manifests/oos15/oneplus_13_global_6.6.56_v.xml`, `manifests/oos15/oneplus_13_global_v.xml`, `manifests/oos15/oneplus_13_v.xml`, `manifests/oos16/oneplus_13_global_6.6.118_w.xml`, and `manifests/oos16/oneplus_13_w.xml`.
- Modify: the six config JSON files enumerated in the matrix interface, setting
  `"module_overlay": false` explicitly in each.

## Task 1 — Establish the exact six-variant executable contract

- [ ] First record the existing known old-test failure, before renaming or implementation:

  ```bash
  bash tests/op13-global-oos16-6.6.118-action-test.sh
  ```

  Expected outcome: the repository's known old-test failure is recorded unchanged.

- [ ] Rename and rewrite it as `tests/op13-all-action-test.sh`. Its initial whitelist assertions must compare exactly these six manifests and no others:

  ```bash
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
  ```

- [ ] Require `.github/workflows/build-op13-all.yml` to declare `push` and `workflow_dispatch`, `strategy.fail-fast: false`, and a matrix `include` equal to the six interface rows. Assert unique slug-prefixed ZIP and artifact names, one all-success non-matrix `publish` job, one dynamic tag/title/table, and exactly one `gh release create`. Assert the `upload_final_zip` default/guard/OP13 override plus the empty `artifact_slug` legacy behavior, safe-character validation, both debug name consumers, and the OP13 caller's `matrix.slug`.

- [ ] Run the new contract immediately after its rewrite:

  ```bash
  bash tests/op13-all-action-test.sh
  ```

  Expected outcome: it fails before the inventory and new workflow are implemented.

## Task 2 — Reduce tracked manifests to the approved whitelist

- [ ] Remove exactly 139 tracked XML manifests using this whitelist-safe generated command. It uses the required recursive tracked-file selector. `artifacts/**` is excluded by constraint and cannot be reached by this selector:

  ```bash
  removed=0
  while IFS= read -r -d '' manifest; do
    case "$manifest" in
      manifests/oos15/oneplus_13_6.6.30_v.xml|manifests/oos15/oneplus_13_global_6.6.56_v.xml|manifests/oos15/oneplus_13_global_v.xml|manifests/oos15/oneplus_13_v.xml|manifests/oos16/oneplus_13_global_6.6.118_w.xml|manifests/oos16/oneplus_13_w.xml) ;;
      *) git rm -- "$manifest"; removed=$((removed + 1));;
    esac
  done < <(git ls-files -z 'manifests/**/*.xml')
  test "$removed" -eq 139
  ```

- [ ] Verify recursive XML inventory/parse validity and the new contract's inventory portion:

  ```bash
  git ls-files 'manifests/**/*.xml' | sort
  find manifests -type f -name '*.xml' -print0 | xargs -0 -r -n1 xmllint --noout
  bash tests/op13-all-action-test.sh
  ```

  Expected outcome: precisely the six `Files`-section manifests remain tracked, all recursive XML parses pass, and the manifest/config assertions pass while workflow assertions may remain failing until Task 3.

- [ ] Delegate manifest-only staging and commit to `git-agent`. It must confirm `git diff -- artifacts/` is empty, stage no artifact, and report its commit SHA.

## Task 3 — Replace the workflow with a verified all-variant release

- [ ] Delete `.github/workflows/build-op13-global-oos16-6.6.118.yml`; create `.github/workflows/build-op13-all.yml`; preserve existing state pins and dispatch inputs. Use the six exact `Interfaces` rows as `strategy.matrix.include`, with `fail-fast: false`.

- [ ] Add optional `upload_final_zip` (default `true`) and `artifact_slug` (default empty) composite-action inputs. Guard final-ZIP upload; validate non-empty slugs through an environment variable and suffix both debug names without changing empty-input legacy names. Pass `matrix.config` and `matrix.slug`; set `archive_final_zip: false` and `upload_final_zip: false`; prefix every built ZIP; create slugged metadata; and upload it as `op13-release-${{ matrix.slug }}`.

- [ ] Extract and validate `.target.kmi`; use it as `kernel_kmi` only for the
  exact Global OOS16 slug and retain the build-output fallback elsewhere.

- [ ] Define one non-matrix `publish` job that `needs: build` and relies on default all-success gating. Reject failure overrides and `continue-on-error` in the contract. Download the six exact artifacts; validate six metadata files, six ZIPs, exact schema/mappings, unique basenames, and recomputed SHA-256 values. Pass only validated ZIP paths to the release command. Build the required Markdown table. Derive only:

  ```bash
  tag="op13-all-r${RUN_NUMBER}-a${RUN_ATTEMPT}"
  title="OnePlus 13 ReSukiSU + SUSFS builds r${RUN_NUMBER}"
  ```

  Invoke `gh release create` once with the dynamic tag, title, Markdown body, and six validated ZIP paths.

- [ ] Run final checks, including the `upload_final_zip` regression contract:

  ```bash
  bash tests/op13-all-action-test.sh
  find manifests -type f -name '*.xml' -print0 | xargs -0 -r -n1 xmllint --noout
  jq -e . configs/oos15/OP13-6.6.30.json configs/oos15/OP13-CPH-6.6.56.json configs/oos15/OP13-CPH.json configs/oos15/OP13-PJZ.json configs/oos16/OP13-GLOBAL-6.6.118.json configs/oos16/OP13.json >/dev/null
  git diff --check
  git status --short
  git diff -- artifacts/
  ```

  Expected outcome: the Bash contract passes, including default-true and guarded-upload assertions for the composite action and the OP13-only false override; all recursive XML and six checked-in config JSON files parse; `git diff --check` is silent; status contains only intended manifest/test/workflow/action changes; and `git diff -- artifacts/` is empty. Runtime release metadata is deliberately not searched in the checked-in tree.

- [ ] Delegate final staging and commit to `git-agent`. Before committing, it must reconfirm artifacts are untouched, stage only the intended manifest/test/workflow paths, and report the commit SHA.

## Task 4 — Separate module overlay from custom patches

**Interfaces:**

- Consumes: JSON `op_config_json`, `OP_CUSTOM_PATCHES`, `KERNEL_VER`,
  `KERNEL_PATCHES_FOLDER`, and `COMMON_KERNEL_FOLDER` from the composite action.
- Produces: validated `OP_MODULE_OVERLAY`; a standalone module-overlay step that
  is enabled only by that variable; six explicit disabled OP13 configurations.

- [ ] Extend `tests/op13-all-action-test.sh` before production changes. Require:
  missing `module_overlay` to export `OP_MODULE_OVERLAY=false`; boolean-only
  validation; exact `"module_overlay": false` in all six matrix configs; a
  standalone step conditioned on `${{ env.OP_MODULE_OVERLAY == 'true' }}`;
  absence of module-overlay patch/copy logic from `Apply Other Patches`; and
  explicit missing patch/modules payload errors in the standalone step.

- [ ] Run the contract in the RED state:

  ```bash
  bash -n tests/op13-all-action-test.sh
  bash tests/op13-all-action-test.sh
  ```

  Expected outcome: syntax passes and the contract fails specifically because
  the independent `module_overlay` behavior has not been implemented.

- [ ] In `.github/actions/build-kernel/action.yml`, make an absent JSON key
  default safely and validate its effective value:

  ```bash
  if ! jq -e 'has("module_overlay")' /tmp/config.json >/dev/null; then
    echo "OP_MODULE_OVERLAY=false" >> "$GITHUB_ENV"
  fi
  module_overlay="${OP_MODULE_OVERLAY:-false}"
  ```

  Reject every effective value except `true` or `false`. Do not add a composite
  action input and do not inherit the value from `custom_patches`.

- [ ] Move the existing overlay patch, conversion, module-selection/copy, and
  ccache-hash logic unchanged into a separate composite step with:

  ```yaml
  if: ${{ env.OP_MODULE_OVERLAY == 'true' }}
  ```

  Preserve the existing `KERNEL_VERSION <= 5.16` skip. For an enabled eligible
  kernel, check the exact patch file and modules directory before changing the
  kernel tree; emit an actionable `::error::` containing the missing path and
  exit non-zero. Leave all non-overlay `custom_patches` behavior unchanged.

- [ ] Add `"module_overlay": false` to exactly the six OP13 JSON configs listed
  in `Files`, without reformatting unrelated keys.

- [ ] Run the GREEN and regression checks:

  ```bash
  bash -n tests/op13-all-action-test.sh
  bash tests/op13-all-action-test.sh
  jq -e . configs/oos15/OP13-6.6.30.json configs/oos15/OP13-CPH-6.6.56.json configs/oos15/OP13-CPH.json configs/oos15/OP13-PJZ.json configs/oos16/OP13-GLOBAL-6.6.118.json configs/oos16/OP13.json >/dev/null
  find manifests -type f -name '*.xml' -print0 | xargs -0 -r -n1 xmllint --noout
  test "$(git ls-files 'manifests/**/*.xml' | wc -l)" -eq 6
  git diff --check
  git diff -- artifacts/
  ```

  Expected outcome: every command succeeds and `artifacts/**` has no diff.

- [ ] Obtain independent code and QA review, commit only the approved files,
  fast-forward `main`, push without force, dispatch `build-op13-all.yml`, and
  verify the run uses the pushed SHA. Completion requires all six matrix jobs
  and the single publish job to succeed; a merely queued run is not sufficient.
