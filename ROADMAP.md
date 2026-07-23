# Volatoo Roadmap

Goal: a Gentoo-based distribution whose root filesystem is a tmpfs, populated at boot from a compressed image, with declarative opt-in persistence.

Phases are sequential; each ends with something bootable or measurable.

## Phase 0 — Prototype (prove the boot path)

Manual, VM-only prototype.

- [x] Boot a stock Gentoo stage3 into tmpfs by hand: custom initramfs `init` script that mounts tmpfs, unpacks a squashfs, `switch_root`s
  - [x] Boot a minimal Volatoo initramfs into a BusyBox rescue shell in QEMU
  - [x] Attach a Gentoo squashfs, populate tmpfs, and `switch_root` into its userspace
- [x] Complete the stock OpenRC boot through a Phase 0 serial console
- [x] Measure: unpack time vs image size (squashfs zstd levels), RAM footprint after boot
- [x] Decide: unpack-into-tmpfs vs squashfs+tmpfs-overlay hybrid (write-layer-only in RAM)
- [x] Write up the boot flow decision in `docs/design/boot.md`

## Phase 1 — volatoo-initramfs

Turn the prototype into a maintainable initramfs generator.

- [x] Standalone initramfs generator with an embedded image-location config
- [x] Image discovery: by-label/by-uuid block device, USB, ISO loopback
- [x] Failure UX: diagnostic summary and a reliable rescue shell on boot errors
- [x] SHA-256 image integrity check before mounting or copying the root
- [x] Boots reliably in QEMU (UEFI + BIOS) from a one-command test harness

## Phase 2 — volatoo-persist

Volatile by default, persistence as policy.

- [x] State partition layout and discovery (label `VOLATOO-STATE`)
- [x] Declarative config: which paths are bind-mounted, which are overlaid, which sync on shutdown
- [x] `/etc` handling: use a three-way merge; document upgrade and conflict semantics
- [x] `volatoo-persist sync` (manual), sync-on-shutdown OpenRC service
- [x] Machine identity that must survive reboot by default: ssh host keys, machine-id, logs (opt-out)

## Phase 3 — volatoo-image

Reproducible image builds instead of hand-rolled squashfs.

- [x] Catalyst-based spec: stage3 + Volatoo overlay + package set → squashfs image
- [x] Volatoo Portage overlay (ebuilds for initramfs/persist tools, profile tweaks)
  - [x] Scaffold `slchris/volatoo-overlay`, live ebuilds, and amd64/23.0 profile
  - [x] Publish the Volatoo sources and pass live `emerge` installation tests
- [x] Kernel config baseline (tmpfs, squashfs+zstd, overlayfs built-in)
- [x] CI pipeline building a weekly minimal image
- [ ] Image variants: `minimal` (console) first; `desktop` later
- [ ] In-place image update: download new image to state partition, reboot into it (A/B slots)

## Phase 4 — Installable release

- [ ] Bootable ISO that is itself a Volatoo system (the live medium *is* the distro)
- [ ] Installer: partition, write image + bootloader + state partition (a script is fine)
- [ ] PXE/diskless boot documented and tested
- [ ] User handbook: install, persist policy, updating, rebuilding your own image
- [ ] Tag v0.1.0 and publish the first image release

## Later / explore

- systemd variant alongside OpenRC
- `binpkg` host so users can `emerge` into the running tmpfs quickly, then bake
- Encrypted state partition (LUKS) unlocked in initramfs
- arm64 support
- "dirty diff" tool: show what changed in tmpfs vs the image, to help decide what to persist or bake
