# OnePlus 13 upstream update — 2026-10-09

Requested firmware: OxygenOS **16.0.10.600**. No matching source publication
was found in the OnePlusOSS SM8750 repositories. The build uses the latest
published OnePlus 13 source release, **16.0.9.401(EX01)**, as requested when
the new firmware sources are unavailable. This does not establish compatibility
with 16.0.10.600.

## Source selection

The `oneplus/sm8750_b_16.0.0_oneplus_13` branch heads in all three repositories
identify 16.0.9.401 in their synchronization commit messages:

| Source | Selected commit |
| --- | --- |
| [Common kernel](https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8750/commit/e1b346b6b4f4096eb342ae3684838a942fd6f6c4) | `e1b346b6b4f4096eb342ae3684838a942fd6f6c4` |
| [Vendor kernel](https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750/commit/6028f47faddaa27700f8dd3a1d83906ea8f27170) | `6028f47faddaa27700f8dd3a1d83906ea8f27170` |
| [Modules and device tree](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750/commit/d50b305f7da9e14715a25120a4ac7b1a4b8b97c3) | `d50b305f7da9e14715a25120a4ac7b1a4b8b97c3` |

The existing Global manifest already pins the common kernel and modules to these
commits. This build uses the common kernel, so the vendor kernel is listed as
release evidence, not added as a second kernel source. The kernel remains
**6.6.118 / android15 KMI**, even though OxygenOS 16 userspace is Android 16.

The official ReSukiSU repository redirects to **Baka-SU/BakaSU**. The build's
`ReSukiSU` input name is retained for existing callers; setup downloads and
commit links now use the canonical repository. Both OP13 state files select
[main commit `8450dd287ef6ee25ca2b6b858b43c9354c73060c`](https://github.com/Baka-SU/BakaSU/commit/8450dd287ef6ee25ca2b6b858b43c9354c73060c)
from October 8. This is a main/CI revision, not a stable release tag.

SUSFS uses **v2.3.0** at
[`937215cb3a1b1f333d764c366c7a49972fa8e7a0`](https://gitlab.com/simonpunk/susfs4ksu/-/commit/937215cb3a1b1f333d764c366c7a49972fa8e7a0),
the observed head of `gki-android15-6.6`. This updates the older pin used by
the all-variant workflow; the experimental workflow already selected this
SUSFS revision. A different Android-generation SUSFS branch must not be used
just because the firmware is OxygenOS 16.

## Validation

The root-driver checkout tests execute the actual composite-action shell steps
with local Git repositories and a download stub. They cover exact SHA success,
SHA mismatch rejection, default main selection, and the ordinary KernelSU path.
The immutable SHA guard now runs in the ReSukiSU step itself; previously it was
misplaced in the ordinary KernelSU step and referenced an unset variable.

Run the repository checks with:

```bash
bash tests/op13-all-action-test.sh
bash tests/op13-baseline-build-test.sh
bash tests/release-workflow-contract-test.sh
bash tests/op13-experimental-resukisu-susfs-contract-test.sh
bash tests/root-driver-checkout-test.sh
```

Full kernel compilation and device boot validation remain pending. To compile
the new Global pair, run **Experimental OP13 Global ReSukiSU/SUSFS validation**
on the update branch in GitHub Actions. It checks the firmware fallback,
immutable source pins, and resolved root/SUSFS revisions, and uploads an
inspection ZIP and diagnostics. The all-variant release workflow also uses the
updated pair, so complete this diagnostic build before merging into `main`.
