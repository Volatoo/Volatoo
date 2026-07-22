# Volatoo

**Volatoo** (*volatile* + *Gentoo*) is a Gentoo-based distribution that runs entirely from RAM: the root filesystem is a tmpfs, populated at boot from a compressed system image. Disks are demoted to cold storage — the OS itself lives in memory.

> Status: early design / prototyping. Nothing bootable is published yet — see [ROADMAP.md](ROADMAP.md).

## Why

- **Speed** — every read and write on `/` happens at RAM speed. No I/O scheduler, no disk latency, no filesystem journaling overhead.
- **A pristine system on every boot** — the running system is disposable by construction. Reboot and you are back to a known-good image. Configuration drift, leftover state, and half-finished experiments evaporate.
- **Practical immutability without read-only pain** — unlike image-based immutable distros, `/` stays fully writable. You can `emerge` packages, edit anything, break anything. It just doesn't survive a reboot unless you ask it to.
- **Zero disk wear, optional disk at all** — the storage device is only touched to load the image and to sync explicitly persisted state. A Volatoo machine can run diskless from PXE.
- **Gentoo underneath** — full Portage, your USE flags, your kernel. Volatoo is a boot/lifecycle layer on top of Gentoo, not a fork of it.

## How it works (design)

```
bootloader
   └─ kernel + volatoo-initramfs
        ├─ mount tmpfs on /newroot
        ├─ locate system image (disk / USB / PXE)
        ├─ unpack squashfs image into tmpfs
        ├─ apply persistence overlays (/etc, /var, /home …)
        └─ switch_root into RAM
             └─ OpenRC boots a normal Gentoo — from memory
```

Three cooperating pieces:

| Component | Role |
|---|---|
| `volatoo-initramfs` | Initramfs generator: mounts tmpfs, unpacks the image, applies persistence, `switch_root` |
| `volatoo-image` | Builds the compressed rootfs image from a Gentoo stage3 + package set (catalyst-based) |
| `volatoo-persist` | Declarative persistence: which paths survive reboot, and how they sync back to disk |

### Persistence model

Everything is volatile by default. Persistence is opt-in and declarative:

- **bind/overlay paths** — e.g. `/home`, `/var/lib` mounted from real storage at boot
- **sync-on-demand / sync-on-shutdown** — e.g. `/etc` snapshots written back to the state partition
- **rebuild into the image** — the "correct" way to make a change permanent: bake it into the next system image

## Requirements (target)

- x86_64, UEFI or BIOS
- RAM ≥ 8 GiB recommended (image size + working set; a minimal image targets ~2 GiB unpacked)
- Any block device, USB stick, or PXE server to hold the boot image — or no disk at all

## Repository layout (planned)

```
initramfs/   volatoo-initramfs sources and dracut-style modules
image/       image build specs (catalyst specs, package sets, profiles)
persist/     volatoo-persist tool and default policies
docs/        design notes and user documentation
```

## Contributing

The project is in the design phase — issues and discussions about the boot flow, persistence semantics, and image tooling are the most valuable contribution right now. See [ROADMAP.md](ROADMAP.md) for where things stand and [AGENTS.md](AGENTS.md) for repository conventions (commit style included).

## License

GPL-2.0 (same spirit as Gentoo itself). A `LICENSE` file will be added with the first code drop.
