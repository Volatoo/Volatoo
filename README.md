# Volatoo

**Volatoo** (*volatile* + *Gentoo*) is a Gentoo-based distribution that runs entirely from RAM: the root filesystem is a tmpfs, populated at boot from a compressed system image. Disks are demoted to cold storage — the OS itself lives in memory.

> Status: Phases 0 through 2 are complete; Phase 3 now has a validated Catalyst
> minimal-image build, with the remaining release-image work tracked below.
> No release image is published yet — see [ROADMAP.md](ROADMAP.md).

## Why

- **Speed** — every read and write on `/` happens at RAM speed. No I/O scheduler, no disk latency, no filesystem journaling overhead.
- **A pristine system on every boot** — the running system is disposable by construction. Reboot and you are back to a known-good image. Configuration drift, leftover state, and half-finished experiments evaporate.
- **Practical immutability without read-only pain** — unlike image-based immutable distros, `/` stays fully writable. You can `emerge` packages, edit anything, break anything. It just doesn't survive a reboot unless you ask it to.
- **Zero disk wear, optional disk at all** — the storage device is only touched to load the image and to sync explicitly persisted state. A Volatoo machine can run diskless from PXE.
- **Gentoo underneath** — full Portage, your USE flags, your kernel and your
  choice of OpenRC or systemd. Volatoo is a boot/lifecycle layer on top of
  Gentoo, not a fork of it.

## How it works (design)

```
bootloader
   └─ kernel + volatoo-initramfs
        ├─ locate system image (disk / USB / PXE)
        ├─ discover the optional VOLATOO-STATE filesystem
        ├─ select and verify current (or previous) system generation
        ├─ verify the base, ordered layers, tombstones, and provenance objects
        ├─ mount tmpfs on /newroot
        ├─ materialize the base plus system layers
        ├─ apply persistence policies (/etc, /var, /home …)
        ├─ restore machine identity and persistent logs
        └─ switch_root into RAM
             └─ the selected init system boots a normal Gentoo — from memory
```

Three cooperating pieces:

| Component | Role |
|---|---|
| `volatoo-initramfs` | Initramfs generator: mounts tmpfs, unpacks the image, applies persistence, `switch_root` |
| `volatoo-image` | Builds the compressed rootfs image from a Gentoo stage3 + package set (catalyst-based) |
| `volatoo-persist` | Declarative persistence: which paths survive reboot, and how they sync back to disk |

### Persistence model

Without a state filesystem, everything is volatile. When state is present,
machine identity and logs persist by default so one installed machine does not
change identity on every boot; each default can be disabled explicitly.
Additional persistence is opt-in and declarative:

- **bind/overlay paths** — e.g. `/home`, `/var/lib` mounted from real storage at boot
- **sync-on-demand / sync-on-shutdown** — e.g. `/etc` snapshots written back to the state partition
- **promote into a system generation** — package transactions become small,
  immutable system layers; complete image rebuilds are reserved for releases
  and layer compaction

See [`docs/design/machine-identity.md`](docs/design/machine-identity.md) for
the machine-id, SSH host-key, log, and opt-out semantics.
The atomic package update and Portage Engine boundary is specified in
[`docs/design/atomic-package-updates.md`](docs/design/atomic-package-updates.md).
OpenRC and systemd minimal images both pass the overlay-root BIOS and UEFI
boot gates. They are separate, first-class release targets; users select one
during image installation or generation selection rather than converting the
init system with an ordinary package layer.

## Requirements (target)

- x86_64, UEFI or BIOS
- RAM ≥ 8 GiB recommended (image size + working set; a minimal image targets ~2 GiB unpacked)
- Any block device, USB stick, or PXE server to hold the boot image — or no disk at all

## Repository layout

```
initramfs/   standalone volatoo-initramfs sources and default configuration
image/       image build specs (catalyst specs, package sets, profiles)
kernel/      amd64 kernel baseline and build guidance
persist/     volatoo-persist tool and default policies
update/      atomic update contracts, binpkg acquisition and layer composition
docs/        design notes and user documentation
```

The reproducible minimal-image entry point is
`scripts/build-catalyst-squashfs.sh`; see
[`image/catalyst/README.md`](image/catalyst/README.md) for its pinned-input
workflow and Docker requirements.

The official Gentoo package repository is maintained separately in
[`slchris/volatoo-overlay`](https://github.com/slchris/volatoo-overlay).

## Contributing

The project is in the design phase — issues and discussions about the boot flow, persistence semantics, and image tooling are the most valuable contribution right now. See [ROADMAP.md](ROADMAP.md) for where things stand and [AGENTS.md](AGENTS.md) for repository conventions (commit style included).

## License

GPL-2.0; see [`LICENSE`](LICENSE).
