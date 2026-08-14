# Kernel baseline

Volatoo keeps its amd64 kernel policy as a Kconfig fragment rather than a
version-specific generated `.config`. The fragment is merged on top of the
selected Linux kernel's `x86_64_defconfig`, resolved by that kernel's own
Kconfig implementation, and then checked for lost requirements.

The boot-critical options in [`config/amd64.fragment`](config/amd64.fragment)
are all built into the kernel. In particular, tmpfs, SquashFS with Zstd,
OverlayFS, ext4, loop devices, device-mapper with dm-verity, virtio block, USB
mass storage, and the serial console cannot be modules: the standalone Volatoo
initramfs does not ship a kernel module tree.

## Prepare a configuration

Use a supported Linux source tree and a dedicated output directory:

```sh
scripts/prepare-kernel-config.sh /usr/src/linux out/kernel-build
```

The script starts from `x86_64_defconfig`, merges the baseline, runs
`olddefconfig`, and fails if Kconfig cannot retain any requirement. It marks
its output directory before reuse so an unrelated build tree is never
overwritten accidentally.

Build the kernel and modules with the same output directory:

```sh
make -C /usr/src/linux O="$PWD/out/kernel-build" -j"$(nproc)" bzImage modules
```

For a host-independent release build, the repository pins Linux 6.18.40 and
its kernel.org SHA-256 digest. The wrapper uses an amd64 cross-compiler in a
native OrbStack container and retains downloads and objects in a named volume:

```sh
scripts/build-kernel-docker.sh out/vmlinuz-6.18.40-volatoo
```

Install the matching modules into the Catalyst image before relying on any
optional driver configured as a module. Modules are not required for Volatoo's
image discovery or tmpfs handoff.

To audit any already-generated configuration:

```sh
scripts/validate-kernel-config.sh /path/to/.config
```

## Baseline scope

The first console image targets amd64 BIOS and UEFI machines. The baseline
covers:

- the initramfs, devtmpfs, procfs, sysfs, and tmpfs handoff;
- raw SquashFS, SquashFS files on ext4 or ISO9660, and optional OverlayFS mode;
- dm-verity authenticated SquashFS reads with SHA-256 and 4096-byte blocks;
- virtio, NVMe, AHCI, and USB mass-storage image/state devices;
- GPT and MBR partition tables;
- serial diagnostics and rescue access;
- virtio and common QEMU Intel network devices for DHCP and SSH.

Hardware-specific drivers outside this set may be built in or supplied as
matching modules by a future kernel package. Secure Boot, kernel/UKI signing,
and module installation policy belong to the release-image work rather than
this boot baseline. Realization metadata uses its separate Ed25519 trust
contract described in `docs/design/release-trust.md`.

## Validation record

On 2026-07-29 the fragment was merged into `x86_64_defconfig` and resolved with
Linux 6.18.40's Kconfig implementation. All 60 requirements remained built in.
This records compatibility with the selected LTS line; release builds still
need to pin and verify their exact kernel source archive.
