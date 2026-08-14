# Release media contract

The first installable Volatoo artifact is a raw GPT disk image. It is a
developer-preview transport for the already validated immutable root and does
not weaken the production realization-signature contract.

## Disk layout

| Partition | GPT type | Filesystem | Purpose |
|---|---|---|---|
| 1 | BIOS boot | none | GRUB BIOS core image |
| 2 | EFI system | FAT32, `VOLATOOESP` | GRUB EFI or a signed UKI, plus BIOS kernel/initramfs and boot configuration |
| 3 | Linux filesystem | ext4, `VOLATOO-SYSTEM` | Read-only source container for `volatoo/root.squashfs` |
| 4 | Linux filesystem | ext4, `VOLATOO-STATE` | Writable state layout and generation store |

The same image must boot through legacy BIOS and UEFI. An unsigned development
image uses GRUB for both paths. A Secure Boot image retains GRUB for BIOS and
uses a signed unified kernel image (UKI) at `EFI/BOOT/BOOTX64.EFI` for UEFI.
Both paths pass only stable labels to the initramfs; Linux device enumeration
order is never part of the contract.

## Development integrity mode

The initial assembler records the root SquashFS SHA-256 in `grub.cfg` and boots
the direct image in `store-overlay` mode. This detects corruption but is not a
release authenticity boundary because an attacker able to replace the boot
partition can replace both the digest and initramfs.

Production release media must instead contain an authenticated generation
state, an initramfs with the matching Ed25519 public key, and an outer Secure
Boot or equivalent verified-boot anchor. The assembler can now create the
outer anchor, but direct-image output remains labelled `v0.1-dev`: Secure Boot
authenticates its kernel, initramfs and command line, while the direct root is
still a development integrity mode rather than the signed-generation release
contract.

## Builder boundary

Partitioning, filesystem creation and GRUB installation run only inside the
pinned privileged release container through the OrbStack Docker context. The
host wrapper accepts regular input files, creates one new regular output file,
and refuses to overwrite an existing path. It never accepts or writes a host
block device. After the container exits, the wrapper independently rechecks
the published file size, image digest, rootfs digest and manifest identity from
the host-visible paths. A writeback or bind-publication drift therefore fails
closed before the image can reach the installer.

## Acceptance gates

1. Inspect the GPT types, filesystem labels and embedded manifest.
2. Boot the raw disk under QEMU BIOS, UEFI and enrolled-key Secure Boot through
   OrbStack.
3. Reach the selected real OpenRC or systemd PID 1 from an unmodified Catalyst
   root image.
4. Reject a changed root SquashFS before mounting it.
5. Change one byte in the signed UKI and require firmware signature rejection
   before the Volatoo initramfs starts.
6. Preserve state across two boots while discarding the tmpfs upper layer.

## Commands

Build an OpenRC developer disk from already verified inputs:

```sh
scripts/build-release-disk-docker.sh \
  --init-system openrc \
  --kernel out/bzImage \
  --initramfs out/volatoo-initramfs.cpio.gz \
  --rootfs out/volatoo-minimal-openrc.squashfs \
  --state out/volatoo-state.ext4 \
  out/volatoo-v0.1-dev-openrc.img
```

The systemd command differs only in `--init-system`, root image and output
name. The wrapper refuses any Docker context other than `orbstack`.

Build a Secure Boot disk with an operator-owned RSA private key and matching
X.509 certificate:

```sh
scripts/build-release-disk-docker.sh \
  --init-system systemd \
  --kernel out/bzImage \
  --initramfs out/volatoo-initramfs.cpio.gz \
  --rootfs out/volatoo-minimal-systemd.squashfs \
  --state out/volatoo-state.ext4 \
  --secure-boot-key /secure/path/db.key \
  --secure-boot-cert /secure/path/db.crt \
  out/volatoo-v0.1-dev-systemd-secure.img
```

The key and certificate are mounted read-only for the network-disabled build
step and are never copied into the disk. The UKI embeds the kernel, initramfs,
command line and OS release metadata. Its Authenticode `signingTime` is fixed
inside the isolated builder so identical inputs produce the same signed UKI.
The whole raw disk is not yet bit-reproducible because filesystem, GPT and GRUB
metadata still vary.

Boot the complete disk through both firmware implementations:

```sh
scripts/test-release-disk-docker.sh \
  --init-system openrc \
  out/volatoo-v0.1-dev-openrc.img
```

The Gate mounts the disk read-only, gives QEMU a temporary snapshot, and
requires the image and state labels, SHA-256 verification, store-overlay root,
persistent identity, real PID 1 and a login prompt. The OpenRC and systemd
disks have passed this Gate under BIOS and OVMF UEFI. A signed systemd disk
additionally passed enrolled-key OVMF Secure Boot. Two independent builds
produced the same signed UKI SHA-256. After one UKI byte was changed, OVMF
reported a security violation and never entered the Volatoo initramfs.

The repository can export Debian OVMF's snakeoil key for this QEMU-only Gate:

```sh
scripts/prepare-secure-boot-test-key-docker.sh out/secureboot-test
scripts/test-release-disk-docker.sh \
  --init-system systemd \
  --firmwares uefi-secure \
  out/volatoo-v0.1-dev-systemd-secure.img
```

That key is public test material and must never be used for a release. The
tamper helper and rejection Gate are:

```sh
scripts/tamper-release-efi-docker.sh signed.img tampered.img
scripts/test-release-disk-docker.sh \
  --init-system systemd \
  --firmwares uefi-secure \
  --expect-secure-rejection \
  tampered.img
```

Install a release image only to an explicit block device:

```sh
sudo scripts/install-volatoo.sh \
  --device /dev/DEVICE \
  --init-system openrc \
  --image out/volatoo-v0.1-dev-openrc.img \
  --ssh-authorized-key "$HOME/.ssh/id_ed25519.pub"
```

The installer verifies the sidecar manifest, image size, SHA-256 digest,
selected init system and destination capacity before writing. It refuses
symlink destinations, mounted targets and the current root disk, then requires
the operator to type the exact device path unless `--yes` is supplied. When the
destination is larger than the image, partition 4 and its ext4 filesystem are
expanded to consume the remaining usable space while retaining their start
sector and partition identity.

The public key is installed into the state partition, not baked into the
immutable image. At every boot the early handoff creates or refreshes a
password-disabled `volatoo` administrator, installs the persisted keys, denies
root and password SSH, and then starts the selected init system. DHCP and sshd
are enabled for both OpenRC and systemd. An unattended image writer may use
`--no-provision-access`, but that leaves the installed system without an
administrator login and must be an explicit choice.
