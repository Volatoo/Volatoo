# PXE / diskless boot

Status: documented and tested for the BIOS lane; UEFI network boot blocked by
the offline toolchain (see [UEFI lane](#uefi-lane)).

## What PXE/diskless means for Volatoo

A *diskless* Volatoo client boots with no persistent system store of its own.
The kernel and the initramfs arrive over the network; the root image arrives as
a block device that is released after the initramfs has copied and re-verified
the compressed closure into RAM. At runtime the machine depends on no local
storage: the writable root is a disposable tmpfs OverlayFS upper, and the lower
is a read-only SquashFS held entirely in RAM.

This is the existing `volatoo.root=ram-overlay` mode combined with
`volatoo.state=none`. Neither the kernel, the initramfs, nor the initramfs
itself performs any network fetch: the initramfs only ever locates the boot
image from a block device (`/dev/...`, `LABEL=...`, `UUID=...`) or from
`volatoo.image-file=` on a mounted medium. PXE therefore only *delivers the
kernel and initramfs*; the root image must still reach the client as a block
device. That delivery is the part a PXE deployment must solve, and it is the
part this note is precise about.

## Topology

```
DHCP/TFTP server                 client (no persistent disk)
  kernel + initramfs  ──TFTP──►  PXE/iPXE option ROM
                                 kernel starts, initramfs runs
                                 ├─ discover image block device
                                 ├─ mount container, read squashfs file
                                 ├─ verify SHA-256, copy compressed closure to RAM
                                 ├─ release the source device
                                 └─ switch_root into a RAM-backed overlay
```

Two delivery stages, one Volatoo-provided and one deployment-provided:

1. **Kernel + initramfs over the network** (PXE ROM). The client firmware's
   PXE/iPXE ROM performs DHCP, then fetches a boot program over TFTP (or HTTP
   when the ROM supports it). For a Linux kernel plus an initrd, the ROM loads
   a bzImage and an initrd and jumps into the kernel with an initramfs. Volatoo
   ships no special loader here: the ROM must support bzImage/initrd, or a
   bootloader such as GRUB must sit between the ROM and the kernel.

2. **Root image as a block device** (the diskless part). The initramfs mounts
   the image container and reads the SquashFS named by `volatoo.image-file=`.
   In `ram-overlay` it then copies the *compressed* closure into tmpfs,
   re-hashes the RAM copy, remounts it read-only, and unmounts the source
   container before `switch_root`. The source device is released, so the client
   is diskless from that point on.

How the root image reaches the client is a deployment choice, not an initramfs
feature:

- **Local removable medium** — the same authenticated live ISO (`openrc-live.iso`
  or `systemd-live.iso`) that carries `/volatoo/root.squashfs` is attached as a
  USB stick or CD. The kernel command line names it with
  `volatoo.image=LABEL=... volatoo.image-file=/volatoo/root.squashfs`. The
  medium is present only at boot and is released after the RAM snapshot.

- **iPXE HTTP SAN** — an iPXE ROM with HTTP and SAN support fetches the ISO over
  HTTP with `sanboot http://server/volatoo-live.iso` and exposes it to the
  firmware as a block device (a disk, not a CD-ROM). The kernel then sees it as
  an ordinary disk (e.g. `/dev/vda` or `/dev/sda`) and the same
  `volatoo.image-file=` path applies. This is the fully network-delivered,
  truly diskless variant. The QEMU test models exactly this: the ISO is attached
  as a virtio-blk disk and consumed through `volatoo.image=/dev/vda
  volatoo.image-file=/volatoo/root.squashfs`.

## Trust boundary

Precise statement of what is and is not authenticated by the existing
mechanisms. It is important not to imply that a network boot payload is
verified when it is not.

| Bytes | Mechanism | Authenticated? |
|---|---|---|
| Kernel + initramfs fetched over TFTP/HTTP | none (stock PXE/iPXE ROM does not verify signatures) | **No** — an active network attacker can substitute both |
| `volatoo.image-sha256=` expectation on the kernel command line | carried in the same unauthenticated iPXE script | **No** — it arrives from the same network as the kernel |
| Root SquashFS content | `volatoo.image-sha256=` eager SHA-256 in `ram-overlay` | Integrity against corruption only; **not authenticity** (the expectation itself is network-supplied) |
| Generation / realization plan / dm-verity root hash | `signify` Ed25519 over the realization plan | **Not reached** — `volatoo.state=none` disables generation selection, so no release-key verification happens at all |

Consequences, stated plainly:

- A diskless boot in `ram-overlay` + `volatoo.state=none` performs **no
  release-key authentication**. The Ed25519 release chain that protects
  `store-overlay` generations is not consulted, because there is no state
  filesystem and no generation to select.
- The only cryptographic check is the SHA-256 of the root SquashFS against an
  expected digest supplied on the (unauthenticated) kernel command line. That
  detects accidental corruption and a naive copy that forgets to update the
  hash, but not a network attacker who controls the boot path.
- The image container itself (the ISO) is **not** verified in the diskless test:
  only the SquashFS file read out of it is hashed. The live ISO's own release
  signature (`org.volatoo.live-media-release/v1`) is an external descriptor
  verified by the operator out-of-band, not by the initramfs.

Closing the gap is future work and is explicitly out of scope here. The two
mechanisms that would do it are a Secure Boot-signed UKI delivered by PXE (which
binds the kernel, initramfs and its embedded release key), and/or an iPXE ROM
with a pinned trust anchor performing HTTPS plus signature verification of the
fetched payload.

## Out of scope

- No NFS root, no iSCSI root, no `nbd` root, no HTTP-fetch of the root image
  inside the initramfs. The initramfs never touches the network.
- No signature verification of the TFTP/HTTP payload, and no Secure Boot over
  PXE. The diskless boot is integrity-checked but not authenticated.
- No persistence: `volatoo.state=none` means machine identity, logs and any
  opt-in persistence are absent. This is intentional for stateless nodes.
- DHCP/SSH provisioning that a real deployment layers on top of the boot is
  documented in the handbook but is not part of the boot contract.

## Test coverage

`scripts/tests/test-pxe-diskless-docker.sh` boots the real pinned kernel and the
full signify/verity initramfs over QEMU's built-in TFTP using the shipped
iPXE option ROM, in the `ram-overlay` + `volatoo.state=none` configuration, and
asserts the same markers as the release Gates: initramfs reached, image device
resolved, SHA-256 verified, source image released, RAM-backed overlay root
ready, real PID 1, and the login prompt.

### UEFI lane

The UEFI lane is not covered, and the reason is concrete rather than a
preference:

- The `ipxe-qemu` package ships a legacy BIOS option ROM
  (`pxe-e1000.rom`) whose feature set includes `bzImage`, so it boots a Linux
  kernel with an initrd over TFTP. Its UEFI companion (`efi-e1000.rom`) reports
  only `DNS HTTP iSCSI NFS TFTP AoE EFI Menu` — **no `bzImage`** — so it can
  fetch the kernel and initrd but cannot hand the initrd to the kernel; the
  guest then panics with `VFS: Unable to mount root fs`.
- Debian's `ovmf` (`OVMF_CODE.fd` and `OVMF_CODE_4M.fd`) ships no network
  stack (`Mtftp4Dxe`, `SnpDxe`, `MnpDxe`, `ArpDxe`, `Ip4Dxe`, `Dhcp4Dxe`,
  `Udp4Dxe` are all absent), so there is no native UEFI PXE path to fall back
  to.
- Building a `bzImage`-capable iPXE EFI ROM, or a `grubnetx64.efi` for the ROM
  to chain, requires toolchains that are not available in the offline pinning
  container.

Enabling UEFI PXE is therefore a follow-up that adds a network-built iPXE EFI
ROM (or GRUB netboot) as a pinned input; it is deliberately not faked.
