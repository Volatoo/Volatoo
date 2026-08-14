# Boot flow design

Status: Phase 0 measurements retained; release architecture revised in Phase 3.

## Current decision: persistent immutable store

The release default follows the NixOS performance model:

1. Keep the selected, content-addressed system closure on persistent storage.
2. Mount its SquashFS read-only and read compressed blocks on demand.
3. Put only OverlayFS `upper` and `work` on tmpfs.
4. Select a different generation by atomically changing a small pointer and
   rebooting, not by overwriting the running system.
5. Keep `ram-overlay` as an explicit removable-media/PXE mode and `copy` as a
   compatibility/debug mode.

The runtime root is writable but disposable. Immutability belongs to the
selected system closure, not to the merged `/` mount. This avoids expanding
roughly 2.6--2.8 GiB and 134,000 inodes on every boot and leaves the page cache
to load only the working set.

The ordinary update path now publishes an incremental realization bound to the
generation digest and its exact verified boot plan. The base and every FHS
update layer have independent dm-verity metadata. The initramfs opens them as
one ordered read-only OverlayFS lower stack; deletion semantics are already
encoded as whiteouts or opaque directories, so it does not replay generation
tombstones into the writable root. A complete single-SquashFS realization
remains the release-image and compaction path. Legacy layer replay remains only
as generation-v1 recovery compatibility for stores created before realization
support.

Packages inside that closure retain the normal Gentoo/FHS paths. Volatoo uses
NixOS-style generation semantics at the whole-system boundary rather than
making `/nix/store` a package runtime prefix.

The host now sees the system store through a read-only bind mount; only the
serialized updater receives a private writable publication view.
Realization v2 adds a deterministic dm-verity hash tree for one complete
closure. Realization v3 binds one such authenticated image record for the base
and every FHS layer, plus the ordered composition and whiteout contracts. The
initramfs hashes the small plan, checks object types and sizes, then lets the
kernel authenticate SquashFS blocks when they are read. It no longer hashes
the complete closure on every `store-overlay` boot. Full hashing happens while
objects are imported and during an explicit `volatoo-generation scrub`.
Realization v1 remains bootable with eager full-file SHA-256. `ram-overlay`
also retains eager SHA-256 because it must prove the copied RAM snapshot before
releasing its source.

Release mode verifies an OpenBSD `signify` Ed25519 signature over the exact
realization-plan bytes before parsing the dm-verity root hash. The public key
is embedded in the initramfs and the state carries only detached signatures.
This proves that the complete generation binding and root hash came from a
trusted release key. `current` may still select an older validly signed
generation because rollback is intentional. Release media can now use a signed
UKI and Secure Boot to authenticate the initramfs and its embedded key; replay
prevention additionally requires protected monotonic state. See
[`release-trust.md`](release-trust.md).

The first x86_64-TCG development Gate used a 574,824,448-byte OpenRC closure
and a 4,534,272-byte verity tree (about 0.79% overhead). Realization-v2
`store-overlay` reached the verified shell in 11 seconds under BIOS and 12
seconds under UEFI. Flipping the first stored byte of either the SquashFS
object or the
verity object made the authenticated SquashFS mount fail. Earlier
realization-v1 compatibility on a different development kernel took 35
seconds, so the result demonstrates removal of the dominant eager-hash delay
but is not a controlled reference-hardware benchmark.

The signed-plan Gate on the same closure reached the verified shell in 11
seconds under BIOS and 13 seconds under UEFI. A wrong embedded key and a
modified detached signature were both rejected before the root mapping was
accepted. `allow-unsigned` separately retained the old realization-v2 recovery
path at 11 seconds under BIOS.

The first signed realization-v3 two-layer fixture reached the verified OpenRC
payload under BIOS and UEFI in 38 and 62 seconds on a different temporary
development kernel. It preserved remove and remove-then-replace behavior.
Changing a layer data block or a used base hash-tree block was rejected at the
authenticated SquashFS mount. Its incremental realization took about 66
seconds with a warm amd64 Docker builder, compared with roughly ten minutes
for complete-closure realization in the same cross-architecture development
environment. These figures are workflow evidence, not a controlled
reference-hardware benchmark.

A rebuilt signed realization-v3 fixture for each real init system was measured
with `qemu-system-x86_64` in the pinned OrbStack runner. With the same current
kernel and 8 GiB TCG guest, root authentication and `switch_root` completed in
4 seconds under BIOS and 7 seconds under UEFI. Systemd reached PID 1 in 12 and
13 seconds, the fixture-owned core-service marker in 25 and 27 seconds, and the
serial login in 38 and 40 seconds. OpenRC reached PID 1 in 10 and 12 seconds,
the same marker in 37 and 39 seconds, and the login in 41 and 43 seconds.

The retained systemd console trace identifies its development-environment
tail: a `/dev/ttyS0` device job had already waited 14 seconds before udev found
the device and systemd started the serial getty. OpenRC spent most of its time
before the core marker running boot-runlevel services sequentially and only
four seconds after it. The serial login remains the end-to-end Gate instead of
changing the test console to improve the reported number; the earlier marker
is the init/service-body diagnostic. Repeated TCG timings vary, but this phase
ordering is stable. These observations are useful for regression and service
ordering, not reference-hardware boot targets.

## Historical question under test

Phase 0 evaluated copying the complete compressed root filesystem into tmpfs
against keeping the squashfs mounted with a tmpfs overlay. The selected design
at that time was the complete tmpfs copy because the original product
definition required the running system to stop depending on image storage.

## Prototype checkpoints

1. Boot an x86_64 kernel with a minimal Volatoo initramfs and enter a BusyBox
   rescue shell in QEMU.
2. Attach a squashfs image, mount tmpfs at `/newroot`, copy the image contents,
   and `switch_root` into a Gentoo stage3.
3. Record compressed size, copy time, total boot time, and memory usage for the
   selected squashfs Zstd levels.
4. Repeat with squashfs plus a tmpfs overlay and document the trade-off.

All four checkpoints are complete.

## First image result

The Docker-built image uses the official amd64 Gentoo stage3 OCI image and 1
MiB SquashFS blocks:

```text
gentoo/stage3@sha256:b5317fd2127e15ace5ff7a2c8aab1ed37a22736a8218546f3b00b4d94b78e500
```

| Zstd level | Docker build | Image size | Native extract, 1 CPU |
|---:|---:|---:|---:|
| 3 | 16 s | 674,496,512 bytes | 3 s |
| 10 | 13 s | 626,860,032 bytes | 2 s |
| 15 | 26 s | 621,965,312 bytes | 3 s |
| 19 | 50 s | 574,746,624 bytes | 2 s |

The native extraction column was measured with `unsquashfs` in a host-native
Alpine container using one processor. It is a compression reference, not a
substitute for the initramfs mount-and-copy measurement under target QEMU.
Level 19 is selected: it saves about 47 MiB over level 15 without a measurable
extraction penalty. The extra build time is acceptable for an image that is
built once and booted many times.

The uncompressed stage3 contains 2,961,144 KiB across 134,221 inodes. Its large
size is not Docker build residue: roughly 1.35 GiB is the Rust toolchain shipped
in the source stage3. Volatoo kept the stock stage3 intact for the baseline
rather than deleting packages to improve the result.

The complete copy and handoff was validated twice under x86_64 QEMU TCG on an
arm64 macOS host. Copying took 472 seconds and 421 seconds respectively. These
numbers measure slow cross-architecture emulation, not expected x86_64 target
performance.

After `switch_root`, the diagnostic stage3 shell reported:

```text
tmpfs / tmpfs rw,relatime,size=3215792k,mode=755,inode64 0 0
Gentoo Base System release 2.18
```

With a 4 GiB VM, the copied root used 2.8 GiB of its 3.1 GiB tmpfs allocation
and left only 284 MiB free. Further tests therefore default to 8 GiB.

## OpenRC result

The official stage3 OCI image sets `rc_sys="docker"` in `/etc/rc.conf`, which
causes OpenRC to skip services that do not apply to containers. The Docker
conversion removes this setting before building the squashfs. It also enables
a root auto-login on `ttyS0` strictly for the VM-only prototype.

With the container setting removed, OpenRC 0.63.1 completed the `sysinit`,
`boot`, and `default` runlevels. Services including udev, devfs, root,
localmount, hostname, and local reached the started state, and
`rc-status --crashed` was empty. PID 1 was SysV init in runlevel 3.

The 8 GiB test VM reported a 6.3 GiB root tmpfs at 45% usage, leaving 3.5 GiB
available. A normal OpenRC shutdown also completed and powered off the VM.

## systemd result

The first Catalyst systemd image was built on 2026-07-23 from the official
amd64 systemd stage3 and the stable
`default/linux/amd64/23.0/systemd` profile. Its SquashFS was 598,507,520 bytes
and contained the expected `/usr/bin/init` link to systemd, the selected
profile link, and the enabled Volatoo persistence unit. The OpenRC persistence
script and sysklogd package were absent.

With the root image mounted as the lower layer, the rebuilt OpenRC image
reached a serial login under BIOS and UEFI in QEMU TCG in 23 and 35 seconds.
The systemd r2 image passed in 34 and 36 seconds. A full-copy systemd attempt
spent the validation window expanding the roughly 2.6 GiB root before PID 1
started. This is evidence for the existing copy-mode performance problem, not
an init-system failure. Together with the memory results, it led to retiring
full-copy as the release-default candidate.

The temporary Alpine test kernel does not leave its module tree in the Gentoo
root after `switch_root`, so DHCP reported no valid network interfaces. This is
a test-kernel limitation; the target kernel baseline will build the required
boot and QEMU drivers into the kernel.

## Root layout comparison

Both layouts completed the stock OpenRC boot in the same 8 GiB VM. The times
below are deliberately identified as cross-architecture TCG measurements; they
are useful for comparing the layouts, not predicting native boot time.

| Layout | Boot-to-login | Root/write-layer use | Available memory |
|---|---:|---:|---:|
| Complete tmpfs copy | about 440 s | 2.8 GiB | about 3.5 GiB |
| Squashfs + tmpfs overlay | about 20 s | 64 KiB | 7,933,196 KiB |

The overlay result is compelling for low memory and fast startup, but its lower
filesystem remains the attached squashfs. Reads can still reach the storage
device, the device cannot be removed after boot, and shutdown must account for
the lower and upper mounts that remain dependencies of `/`. Those properties
conflicted with the original promise that the complete operating system would
be copied to RAM and its image storage would become cold storage.

Phase 1 therefore used the complete tmpfs copy as the default and supported
boot design. The `volatoo.root=overlay` prototype remains available for
experiments, but it is explicitly source-backed.

Phase 3 performance results superseded that default. The source-backed design
is now the supported `volatoo.root=store-overlay` path because it matches the
chosen persistent immutable-store model. The old `overlay` spelling remains a
compatibility alias.

## Optional RAM-backed overlay

Phase 3 also adds `volatoo.root=ram-overlay` for workloads that explicitly
require the source device to be released. It creates two independent tmpfs
mounts:

1. Copy the verified compressed SquashFS into the first tmpfs.
2. Hash the RAM copy again and remount that tmpfs read-only.
3. Attach the RAM file through a read-only loop device.
4. Use the mounted SquashFS as the lower and the second tmpfs as the overlay
   upper/work filesystem.
5. Unmount any source image container before handing control to Gentoo.

The running root therefore remains writable and entirely RAM-backed without
expanding every inode during early boot. The original image block device is no
longer a lower-filesystem dependency. A selected system generation can still
keep its state filesystem mounted for persistence, but its base object is not
used as the live lower after the RAM snapshot is verified.

The first cross-architecture QEMU Gate passed with the current OpenRC and
systemd images:

| RAM-overlay check | BIOS | UEFI |
|---|---:|---:|
| Direct image, shell and backing topology | 59 s | 59 s |
| OpenRC generation, normal boot | 100 s | 109 s |
| systemd generation, normal boot | 100 s | 107 s |
| Generation layer/tombstone payload | 74 s | 75 s |
| SquashFS inside a USB ISO, source released | 58 s | not run |

The shell checks require a read-only tmpfs at `/.volatoo/ram-lower`, a
read-only loop-mounted SquashFS lower, a writable tmpfs at
`/.volatoo/writable`, and no `/.volatoo/source` mount. These timings were
recorded under x86_64 TCG on an arm64 macOS host and are comparative rather
than native performance predictions.

`store-overlay` is now the default. The native comparison is implemented by
`scripts/measure-native-root-modes.sh` and deliberately requires an x86_64
Linux host with KVM. It records versioned TSV rows for shell handoff memory and
systemd boot-to-login time in `store-overlay`, `ram-overlay`, and `copy`. Its
policy requires:

- all three systemd modes reach login within 120 seconds;
- both overlay modes are no slower than full copy; and
- both overlay modes retain at least 512 MiB more guest available memory.

These thresholds can be overridden explicitly for a documented reference
machine. TCG measurements cannot complete this Gate.
