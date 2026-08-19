# Authenticated live ISO

The live ISO is a bootable Volatoo system and the formal offline installation
environment. It contains the exact standalone `Volatoo/installer`, release
keyring and signed content-addressed publication bound by releng's
`live-media-inputs/v1` document.

Build it with the OrbStack-only entry point:

```sh
scripts/build-live-iso-docker.sh \
  --init-system openrc \
  --kernel /path/to/vmlinuz \
  --initramfs /path/to/initramfs.cpio.gz \
  --rootfs /path/to/volatoo-minimal-openrc.squashfs \
  --publication /path/to/releng-publication \
  --trusted-key /path/to/release.pub \
  out/volatoo-live-openrc.iso
```

The builder requires Docker context `orbstack`, uses a pinned amd64 container
without network access for the actual assembly, and refuses symlink or special
file inputs. Before construction it verifies the release-index and live-input
signatures, the publication checksum set, all referenced CAS objects and the
index binding. The installer binary and release key inside the SquashFS must
match the signed objects exactly. The live root must also contain every
external command used by the installer.

The output is a BIOS/UEFI hybrid ISO plus an
`org.volatoo.live-media/v1` manifest. ISO filesystem dates, the GPT disk GUID,
the GRUB-generated UUID name and the embedded FAT serial are normalized before
the manifest digest is calculated, so two builds with identical inputs are
byte-identical.

After construction, `Volatoo/releng` signs a canonical
`org.volatoo.live-media-release/v1` descriptor that binds the complete ISO and
manifest bytes back to the exact signed release index, live-media inputs and
release key. Consumers verify this external descriptor before booting the
medium; the two-stage design avoids embedding a signature of the ISO inside
the ISO itself.

Boot both firmware paths through OrbStack QEMU:

```sh
scripts/test-live-iso-docker.sh \
  --init-system openrc \
  --firmwares bios,uefi \
  out/volatoo-live-openrc.iso
```

Complete installation qualification belongs to `Volatoo/qa`: its live-media
Gate boots this ISO, invokes the formal installer against a new explicit target
disk and boots the installed result under both firmware modes.

Run the deterministic-metadata and fail-closed normalization regression test
through the same pinned OrbStack builder image:

```sh
scripts/tests/test-live-iso-normalizer-docker.sh
```
