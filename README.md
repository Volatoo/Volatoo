# Volatoo

**Volatoo** (*volatile* + *Gentoo*) is a Gentoo-based distribution with
NixOS-style immutable system generations and a disposable writable root. The
selected immutable objects remain in a persistent content-addressed store; the
exact realization plan is authenticated by an initramfs-embedded Ed25519
release key, the base and FHS update layers are independently authenticated by
dm-verity, mounted as one read-only lower stack and read on demand, while a
tmpfs OverlayFS upper holds all unpersisted runtime changes.

> Status: Phases 0 through 2 are complete. Phase 3 has validated OpenRC and
> systemd Catalyst targets, and the first installable `v0.1-dev` preview is
> [published](https://github.com/Volatoo/Volatoo/releases/tag/v0.1.0-dev.20260814).
> Remaining release work is tracked in [ROADMAP.md](ROADMAP.md).

## Why

- **Fast startup and low memory amplification** — the kernel reads compressed
  SquashFS blocks only when needed and verifies those blocks through dm-verity,
  instead of expanding or hashing the complete closure during early boot.
- **A pristine system on every boot** — the writable root is disposable by
  construction. Reboot and you are back to the selected immutable generation.
- **Practical immutability without read-only pain** — `/` remains writable
  through a tmpfs upper. Experiments disappear on reboot unless they are
  persisted or promoted into a new generation.
- **Atomic generations and rollback** — content-addressed objects are
  published before an atomic generation-pointer switch. Previous generations
  remain independently bootable.
- **Gentoo underneath** — full Portage, your USE flags, your kernel and your
  choice of OpenRC or systemd. Volatoo is a boot/lifecycle layer on top of
  Gentoo, not a fork of it. Packages keep the normal Gentoo/FHS runtime layout;
  content addressing applies to the complete system closure, not to package
  installation prefixes.

`ram-overlay` remains available for PXE, removable-media, and source-device
release use cases. It copies only the compressed closure to RAM. Full
filesystem expansion with `copy` is retained as a compatibility/debug mode,
not the release default.

## How it works (design)

```
bootloader
   └─ kernel + volatoo-initramfs
        ├─ locate the system store or boot image (disk / USB / PXE)
        ├─ discover the optional VOLATOO-STATE filesystem
        ├─ select and verify current (or previous) system generation
        ├─ verify the small generation, boot-plan and realization bindings
        ├─ authenticate the exact realization plan with a release key
        ├─ open the base and FHS update layers through dm-verity
        ├─ compose the authenticated immutable lower stack read-only
        ├─ create a disposable tmpfs OverlayFS upper
        ├─ use generation-v1 deltas only for legacy compatibility
        ├─ apply persistence policies (/etc, /var, /home …)
        ├─ restore machine identity and persistent logs
        └─ switch_root into the ephemeral merged root
             └─ the selected init system boots a normal Gentoo
```

Three cooperating pieces:

| Component | Role |
|---|---|
| `volatoo-initramfs` | Initramfs generator: mounts the immutable lower and tmpfs upper, applies persistence, `switch_root` |
| `volatoo-image` | Builds the compressed rootfs image from a Gentoo stage3 + package set (catalyst-based) |
| `volatoo-persist` | Declarative persistence: which paths survive reboot, and how they sync back to disk |

Installation is owned by the separate
[`Volatoo/installer`](https://github.com/Volatoo/installer) project. Its formal
release path authenticates a signed, versioned release index before acquiring
content-addressed media or opening an explicit target device. The Bash disk
writer retained in this repository exists only for the published developer
preview and compatibility testing; it is not the installer for future formal
releases.

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
Generation v2 Portage desired-state transitions are specified in
[`docs/design/generation-v2.md`](docs/design/generation-v2.md).
Incremental authenticated realization and OverlayFS tombstone semantics are
specified in
[`docs/design/incremental-realization.md`](docs/design/incremental-realization.md).
The reason Volatoo keeps normal Gentoo paths rather than adopting a
package-level `/nix/store` layout is specified in
[`docs/design/fhs-compatibility.md`](docs/design/fhs-compatibility.md).
The release-key, rollback and Secure Boot boundaries are specified in
[`docs/design/release-trust.md`](docs/design/release-trust.md).
OpenRC and systemd minimal images both pass the overlay-root BIOS and UEFI
boot gates. Signed systemd release media also pass enrolled-key Secure Boot,
including firmware rejection after a signed UKI is changed. They are separate,
first-class release targets; users select one during image installation or
generation selection rather than converting the init system with an ordinary
package layer.

## Requirements (target)

- x86_64, UEFI or BIOS
- RAM ≥ 4 GiB target for the persistent-store mode; 8 GiB recommended for
  full-RAM or large package-build workloads
- A block device for the persistent system store, or PXE/removable media with
  `ram-overlay`

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

Authenticated BIOS/UEFI live media are built by
`scripts/build-live-iso-docker.sh`; see
[`image/live-iso/README.md`](image/live-iso/README.md) for the signed input
contract, reproducibility rules and OrbStack QEMU Gates. The live system ships
the standalone installer and its release keyring, and carries the exact signed
release publication for offline installation.

The official Gentoo package repository is maintained separately in
[`Volatoo/volatoo-overlay`](https://github.com/Volatoo/volatoo-overlay).

Installation, first-boot access, persistence, rollback and reproducible image
build instructions are in the [developer preview handbook](docs/handbook.md).

## Contributing

The project is in the design phase — issues and discussions about the boot flow, persistence semantics, and image tooling are the most valuable contribution right now. See [ROADMAP.md](ROADMAP.md) for where things stand and [AGENTS.md](AGENTS.md) for repository conventions (commit style included).

## License

GPL-2.0; see [`LICENSE`](LICENSE).
