# OnePlus 13 Manifest Matrix Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single Global OOS16 workflow with an exact six-variant build matrix, retain only the six approved XML manifests, and create one release that verifies and publishes all six uniquely named ZIPs.

**Architecture:** `tests/op13-all-action-test.sh` becomes the executable acceptance contract for the approved inventory and workflow rules. `.github/workflows/build-op13-all.yml` runs one matrix build per exact config/manifest pair. Each build produces isolated runtime metadata and one uniquely named artifact; one non-matrix `publish` job verifies all six and makes one GitHub release.

**Tech Stack:** Bash; GitHub Actions YAML; XML; JSON; `jq`; `xmllint`; GitHub CLI (`gh`); Git.

## Global Constraints

- The whitelist is exactly six XML manifests and exactly six checked-in config JSON files; do not introduce variants or infer missing device/region mappings.
- Never alter `artifacts/**`.
- Preserve existing state pins and `workflow_dispatch` inputs.
- Do not change composite actions.
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

## Files

- Modify/rename: `tests/op13-global-oos16-6.6.118-action-test.sh` → `tests/op13-all-action-test.sh`.
- Delete: `.github/workflows/build-op13-global-oos16-6.6.118.yml`.
- Create: `.github/workflows/build-op13-all.yml`.
- Keep only: `manifests/oos15/oneplus_13_6.6.30_v.xml`, `manifests/oos15/oneplus_13_global_6.6.56_v.xml`, `manifests/oos15/oneplus_13_global_v.xml`, `manifests/oos15/oneplus_13_v.xml`, `manifests/oos16/oneplus_13_global_6.6.118_w.xml`, and `manifests/oos16/oneplus_13_w.xml`.
- Validate, but do not rewrite: the six config JSON files enumerated in the matrix interface.

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

- [ ] Require `.github/workflows/build-op13-all.yml` to declare `push` and `workflow_dispatch`, `strategy.fail-fast: false`, and a matrix `include` equal to the six interface rows (including exact paths/slugs/compatibility text). Assert unique slug-prefixed ZIP and artifact names, one non-matrix `publish` job, one dynamic tag/title/table, and exactly one `gh release create`; reject a fixed `Global` title.

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

- [ ] Preserve the existing action inputs and pass only `matrix.config` as `op_config_json` to the composite action. Manifest and compatibility are workflow metadata only because the action has no such inputs. Set `archive_final_zip: false`; rename/prefix every built ZIP with its `slug`; create `release-metadata-${{ matrix.slug }}.json`; and upload its ZIP plus metadata as `op13-release-${{ matrix.slug }}`.

- [ ] Define one non-matrix `publish` job that `needs: build` and relies on default all-success gating. Download the six unique artifacts; validate exactly six metadata JSON files, six unique ZIP filenames, and their SHA-256 values. Build a Markdown table containing the exact fields from **Runtime release metadata**. Derive only:

  ```bash
  tag="op13-all-r${RUN_NUMBER}-a${RUN_ATTEMPT}"
  title="OnePlus 13 ReSukiSU + SUSFS builds r${RUN_NUMBER}"
  ```

  Invoke `gh release create` once with the dynamic tag, title, Markdown body, and six validated ZIP paths.

- [ ] Do not change any composite action. Run final checks:

  ```bash
  bash tests/op13-all-action-test.sh
  find manifests -type f -name '*.xml' -print0 | xargs -0 -r -n1 xmllint --noout
  jq -e . configs/oos15/OP13-6.6.30.json configs/oos15/OP13-CPH-6.6.56.json configs/oos15/OP13-CPH.json configs/oos15/OP13-PJZ.json configs/oos16/OP13-GLOBAL-6.6.118.json configs/oos16/OP13.json >/dev/null
  git diff --check
  git status --short
  git diff -- artifacts/
  ```

  Expected outcome: the Bash contract passes; all recursive XML and six checked-in config JSON files parse; `git diff --check` is silent; status contains only intended manifest/test/workflow changes; and `git diff -- artifacts/` is empty. Runtime release metadata is deliberately not searched in the checked-in tree.

- [ ] Delegate final staging and commit to `git-agent`. Before committing, it must reconfirm artifacts are untouched, stage only the intended manifest/test/workflow paths, and report the commit SHA.
