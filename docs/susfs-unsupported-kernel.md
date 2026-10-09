# SUSFS WebUI: Unsupported Kernel / SUS PATH UNDEFINED

The successful [build run 37908077540](https://github.com/BergaBruh/OnePlus_13_ReSukiSU_SUSFS/actions/runs/37908077540)
compiled `fs/susfs.o`, selected the SUSFS inline hook, passed upstream hook checks,
and reported SUSFS v2.3.0. Compilation alone does not prove that the module can
query the kernel on a particular phone.

The upstream module's WebUI displays this dialog when
`/data/adb/ksu/susfs4ksu/logs/susfs_active` is absent. Its boot script creates that
marker from `ksu_susfs show enabled_features` or SUSFS messages in dmesg. A missing,
outdated, or nonexecutable `/data/adb/ksu/bin/ksu_susfs` can therefore produce the
same message as an unsupported kernel.

The inspected upstream [customize.sh](https://github.com/sidex15/susfs4ksu-module/blob/c6a1c065efff9eaead049acf529a10bc93d34e75/customize.sh)
has an installation path that skips copying the helper when the bundled and
cloud hashes match. It also skips the final helper chmod when SUSFS v2 is detected.
These are possible causes, not a confirmed diagnosis of the reported phone.

## Check and repair on the phone

Download `scripts/susfs-module-repair.sh` from this repository into the phone's
Download folder. Open Termux, grant it root in the root manager, and run:

```sh
su -c 'sh /sdcard/Download/susfs-module-repair.sh --diagnose'
```

If the helper check fails, run:

```sh
su -c 'sh /sdcard/Download/susfs-module-repair.sh --repair'
```

Repair downloads the ARM64 [universal helper at immutable revision
041f69d7](https://github.com/sidex15/susfs4ksu-binaries/tree/041f69d7fe23a7bd928f9bd90eb3535774d00456),
verifies SHA256 `8a626ce3bae27a7bcaa2e7f5f7b91e786ecc57f8e57d19c7856719a89b54b6fa`,
and requires the running kernel to return `v2.3.0` and the SUS_PATH feature before
replacing anything. It backs up an existing helper, sets executable permissions,
and checks the installed helper again. Reboot after repair so the original
module boot scripts apply your saved settings and create their own support marker.
No kernel flash or rebuild is needed for this helper repair.

If the helper already works but the boot marker is absent, reboot first. If the
dialog persists, collect the module's `susfs.log` and `susfs1.log` from
`/data/adb/ksu/susfs4ksu/logs`, plus the diagnostic output. If the replacement
cannot query the kernel, the script stops without replacing the installed helper;
check which kernel was actually flashed and whether the root manager matches
the BakaSU/ReSukiSU kernel revision. Do not force a support marker to conceal an
API failure.

Validation uses mocked downloads and helper responses to cover missing and stale
helpers, executable permissions, checksum failure, download failure, unsupported
kernels, and rollback. It does not replace validation on an Android device.
