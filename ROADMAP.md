# Volatoo Roadmap

Goal: a Gentoo-based distribution whose root filesystem is a tmpfs, populated at boot from a compressed image, with declarative opt-in persistence.

Phases are sequential; each ends with something bootable or measurable.

## Phase 0 — Prototype (prove the boot path)

Manual, VM-only. No tooling yet.

- [ ] Boot a stock Gentoo stage3 into tmpfs by hand: custom initramfs `init` script that mounts tmpfs, unpacks a squashfs, `switch_root`s
- [ ] Measure: unpack time vs image size (squashfs zstd levels), RAM footprint after boot
- [ ] Decide: unpack-into-tmpfs vs squashfs+tmpfs-overlay hybrid (write-layer-only in RAM)
- [ ] Write up the boot flow decision in `docs/design/boot.md`

## Phase 1 — volatoo-initramfs

Turn the prototype into a maintainable initramfs generator.

- [ ] Initramfs generator (dracut module or standalone), config file for image location
- [ ] Image discovery: by-label/by-uuid block device, USB, ISO loopback
- [ ] Failure UX: drop to rescue shell with a useful message when the image is missing/corrupt
- [ ] Image integrity check (sha256 / signature) before unpack
- [ ] Boots reliably in QEMU (UEFI + BIOS) from a one-command test harness

## Phase 2 — volatoo-persist

Volatile by default, persistence as policy.

- [ ] State partition layout and discovery (label `VOLATOO-STATE`)
- [ ] Declarative config: which paths are bind-mounted, which are overlaid, which sync on shutdown
- [ ] `/etc` handling: three-way merge vs snapshot-restore — pick one, document why
- [ ] `volatoo-persist sync` (manual), sync-on-shutdown OpenRC service
- [ ] Machine identity that must survive reboot by default: ssh host keys, machine-id, logs (opt-out)

## Phase 3 — volatoo-image

Reproducible image builds instead of hand-rolled squashfs.

- [ ] Catalyst-based spec: stage3 + Volatoo overlay + package set → squashfs image
- [ ] Volatoo Portage overlay (ebuilds for initramfs/persist tools, profile tweaks)
- [ ] Kernel config baseline (tmpfs, squashfs+zstd, overlayfs built-in)
- [ ] CI pipeline building a weekly minimal image
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
