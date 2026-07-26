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
- [ ] Init-system targets: build and test matching OpenRC and systemd base images
  - [x] Parameterize signed stage3 resolution and Catalyst spec rendering
  - [x] Add init-specific persistence integration to both image roots
  - [x] Complete the first systemd Catalyst build and overlay-root BIOS/UEFI boot
  - [ ] Complete the default full-copy systemd boot performance Gate
- [ ] Let installers and image tooling select `openrc` or `systemd` explicitly
- [ ] Provide equivalent persistence/shutdown integration for OpenRC and systemd
- [ ] Run the image, boot, update and rollback CI matrix against both init systems
- [ ] Package-set variants: `minimal` (console) first; `desktop` later
- [ ] In-place image update: download new image to state partition, reboot into it (A/B slots)

### Phase 3U — Atomic package updates

Keep package maintenance granular while preserving immutable, rollback-capable
system generations. See `docs/design/atomic-package-updates.md`.

- [x] Define the local-build/binhost/Portage Engine architecture and trust boundary
- [x] P3U-0: versioned build-context and generation manifest contracts, including OpenRC/systemd target identity
- [x] P3U-1: local Portage planner producing a canonical BuildSpec
- [x] P3U-2: local binpkg and target-specific remote binhost acquisition for both init systems
- [x] P3U-3: binary-only staged installation and SquashFS layer composer
- [x] P3U-4: atomic generation selection, rollback and OpenRC/systemd QEMU boot coverage
- [ ] P3U-5: service activation policies, garbage collection and base compaction
  - [x] Add fail-closed live service activation with config and health checks
  - [x] Add generation pinning, inspection and mark-and-sweep garbage collection
  - [x] Add verified Docker base compaction and compaction receipts
  - [x] Add the canonical Portage Engine adapter and mocked control-plane Gate
  - [ ] Publish stable OpenRC/systemd Engine targets and run the real signed E2E

## Phase 4 — Installable release

- [ ] Bootable ISO that is itself a Volatoo system (the live medium *is* the distro)
- [ ] Installer: partition, write image + bootloader + state partition (a script is fine)
- [ ] PXE/diskless boot documented and tested
- [ ] User handbook: install, persist policy, updating, rebuilding your own image
- [ ] Tag v0.1.0 and publish the first image release

## Later / explore

- Encrypted state partition (LUKS) unlocked in initramfs
- arm64 support
- "dirty diff" tool: show what changed in tmpfs vs the image, to help decide what to persist or bake
