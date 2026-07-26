# Boot flow design

Status: Phase 0 decision recorded.

## Question under test

Volatoo evaluated copying the complete compressed root filesystem into tmpfs
against keeping the squashfs mounted with a tmpfs overlay. The selected design
is the complete tmpfs copy. It keeps the defining property that the running
system no longer depends on its image storage after boot.

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
an init-system failure; full-copy performance remains a separate release Gate.

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
conflict with Volatoo's promise that the complete operating system is copied to
RAM and its image storage becomes cold storage.

Phase 1 will therefore use the complete tmpfs copy as the default and supported
boot design. The `volatoo.root=overlay` prototype remains available for
experiments and as evidence for a possible future low-memory mode. A future
variant could first copy the compressed image itself to RAM and then overlay it;
that would remove the storage dependency, but it is a distinct design that has
not been measured here.
