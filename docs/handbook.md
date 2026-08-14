# Volatoo developer preview handbook

This handbook covers the `v0.1-dev` amd64 disk images. They are developer
previews, not a stable production release. The images boot through BIOS and
UEFI, offer separate OpenRC and systemd targets, and require an SSH public key
to be provisioned during installation. They do not ship a default password.

The current images and verification files are available from the
[`v0.1.0-dev.20260814` developer preview](https://github.com/Volatoo/Volatoo/releases/tag/v0.1.0-dev.20260814).

## Choose an image

Choose exactly one init-system target:

- `volatoo-v0.1-dev-*-openrc-amd64.img.zst` for OpenRC;
- `volatoo-v0.1-dev-*-systemd-amd64.img.zst` for systemd.

The choice is part of the immutable target identity. Do not install one target
and try to convert it to the other with an ordinary package transaction.

Each preview publication also contains the uncompressed-image manifest and a
`SHA256SUMS` file. Release-media manifest v2 records the exact disk, kernel,
initramfs, Catalyst root, initial state image, Secure Boot certificate and UKI
digests. A value of `secure_boot=no` means the image uses ordinary GRUB UEFI
and must not be described as a Secure Boot image.

## Verify and decompress

Download the selected archive, its matching `.img.manifest`, `INSTALL.md`,
`install-volatoo.sh`, and `SHA256SUMS` into one directory. Verify the
downloaded files before decompression:

```sh
sha256sum --check SHA256SUMS
zstd --test volatoo-v0.1-dev-*-amd64.img.zst
zstd --decompress volatoo-v0.1-dev-*-amd64.img.zst
```

Compare the decompressed disk digest with `disk_sha256` in the matching
manifest:

```sh
sha256sum volatoo-v0.1-dev-*-amd64.img
sed -n 's/^disk_sha256=//p' volatoo-v0.1-dev-*-amd64.img.manifest
```

The two values must be identical. The developer-preview checksum file is not
yet signed by an offline production release key; obtain it from the same
GitHub release as the artifacts and treat that limitation as part of the
preview trust boundary.

## Install to an explicit disk

Run the installer from a Linux environment with Bash, util-linux, GPT fdisk,
e2fsprogs and coreutils installed. The installer does not auto-detect a target
and never selects a disk on the operator's behalf.

Identify the destination independently, unmount its filesystems, and invoke
the installer with the exact device and init-system target:

```sh
sudo ./install-volatoo.sh \
  --device /dev/DEVICE \
  --init-system openrc \
  --image volatoo-v0.1-dev-20260814-openrc-amd64.img \
  --manifest volatoo-v0.1-dev-20260814-openrc-amd64.img.manifest \
  --ssh-authorized-key "$HOME/.ssh/id_ed25519.pub"
```

Use `--init-system systemd` with the systemd image. All data on the explicit
device is destroyed after the installer asks you to type the complete device
path. The installer verifies manifest identity, image size and disk digest,
rejects a mismatched init system, writes the image, expands the state
partition to the destination's remaining usable space, and installs the SSH
key into persistent state.

`--no-provision-access` is intended only for automated image preparation with
another access mechanism. It deliberately leaves the machine without the
default administrator login.

## First boot and access

Boot the installed disk through BIOS or UEFI. The first-boot handoff creates a
password-disabled `volatoo` user with UID 1000, grants passwordless `sudo`,
restores the provisioned `authorized_keys`, enables DHCP and starts SSH.

Find the assigned address from DHCP or the local console, then connect with:

```sh
ssh -i "$HOME/.ssh/id_ed25519" volatoo@VOLATOO_ADDRESS
sudo -n true
```

Root SSH and password authentication are disabled. If key authentication does
not work, fix the state-side access configuration from trusted recovery media;
do not add a default password to the immutable image.

## Persistence

The immutable lower stack is read-only and the writable root is a disposable
tmpfs OverlayFS upper. Arbitrary changes disappear at reboot. Machine identity,
SSH host keys and logs persist by default when the state partition is present.

Additional persistence is declared in
`/.volatoo/state/volatoo/config/persist.conf` with one policy per line:

```text
bind /home home
overlay /var/lib application-state
sync /etc etc
```

Use non-overlapping real directories as targets. Inspect and synchronize
`sync` policies with:

```sh
sudo volatoo-persist status
sudo volatoo-persist sync
```

Read [the persistence policy](design/persistence-policy.md) before changing
the file; `bind`, `overlay` and `sync` have different recovery and deletion
semantics.

## Generations, updates and rollback

The preview includes the Volatoo update CLI and the pinned `signify` verifier.
The public system store is read-only. Mutating commands must run through the
serialized private update view:

```sh
sudo volatoo-update-view \
  volatoo-generation status --state /run/volatoo/update-state
```

After an independently verified and signed generation has been published by
the documented planner, acquisition, layer and realization pipeline, reboot
to enter the selected generation. To atomically select the independently
verified previous generation:

```sh
sudo volatoo-update-view \
  volatoo-generation rollback --state /run/volatoo/update-state
sudo reboot
```

Rollback accepts only a published previous generation that still satisfies
the generation and realization contract. The developer preview does not yet
provide a stable public Portage Engine target or a one-command public package
update service. See [the update contracts](../update/README.md) for the current
operator workflow and its trust boundaries.

## Build your own image

All Docker, image, signing, layer, compression and QEMU work in the supported
macOS development workflow uses the `orbstack` Docker context:

```sh
docker context use orbstack
```

The reproducible build sequence is:

1. Verify and fetch matching Gentoo stage3 and repository-snapshot inputs with
   `scripts/fetch-gentoo-inputs.sh`.
2. Prepare the pinned userspace verifier and release public key set with
   `scripts/prepare-signify-root-docker.sh`.
3. Build the selected Catalyst root with
   `scripts/build-catalyst-squashfs.sh`.
4. Build and validate the pinned kernel with
   `scripts/build-kernel-docker.sh`.
5. Build the release-policy initramfs and initial state image.
6. Assemble the raw disk with `scripts/build-release-disk-docker.sh`.
7. Boot it with `scripts/test-release-disk-docker.sh` before installation or
   publication.
8. Package the validated OpenRC and systemd disks with
   `scripts/package-release-docker.sh`; publish only a directory containing its
   final `SHA256SUMS` marker.

See [the Catalyst build guide](../image/catalyst/README.md),
[release-media contract](design/release-media.md) and
[release trust contract](design/release-trust.md) for exact commands and
production-key boundaries. Never use the repository's OVMF snakeoil fixture as
a release Secure Boot key.
