# Volatoo Roadmap

Goal: a Gentoo-based distribution with NixOS-style immutable,
content-addressed system generations, a persistent read-only system lower, a
disposable tmpfs writable root, and declarative opt-in persistence.

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
  - [x] Retire full-copy as the release-default candidate after performance data
    - [x] Add an auditable native x86_64/KVM root-mode benchmark
    - [x] Select persistent `store-overlay` as the NixOS-style release default
    - [ ] Record reference-hardware `store-overlay` boot and memory metrics
  - [x] Cover generation payloads in store/copy/RAM overlays and selectable firmware QEMU lanes
  - [x] Add a RAM-backed SquashFS overlay that releases the source image device
  - [x] Add an explicit store-backed overlay and make it the default root mode
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
  - [x] Require complete generation provenance, parent-chain validation and CAS activation
  - [x] Reconstruct and verify the selected parent before planning or composing a layer
  - [x] Model Portage config, world, repository and toolchain transitions in generation v2
  - [x] Realize one complete immutable system closure before generation activation
  - [x] Boot a realized closure without replaying package layers or tombstones
  - [x] Enforce the Gentoo/FHS runtime contract before closure realization
    - [x] Resolve ABI-compatible ELF `DT_NEEDED` providers inside the closure
  - [x] Expose the system store read-only to the host and give only the update
        service a private writable publication view
  - [x] Add authenticated lazy reads with dm-verity and move full object
        hashing from every boot to import/scrub
    - [x] Publish deterministic verity trees in realization v2
    - [x] Reject data-block and hash-tree tampering in QEMU
  - [x] Publish an incremental realization that authenticates the base and
        FHS update layers independently, reserving full closure rebuilds for
        compaction and release images
    - [x] Reuse verified dm-verity metadata for unchanged v3 base and layer
          images instead of rebuilding their hash trees for every descendant
    - [x] Retain the materializer's verified object snapshots for the rest of
          one realization instead of rereading mutable state paths
    - [x] Bind an authenticated parent-tree receipt to v3 and avoid repeated
          publication hashing for exact direct-parent inherited objects
    - [x] Replace ordinary complete-tree snapshot hashing with receipt-v3
          compositional tree state bound to the plan and validation index
    - [x] Validate affected FHS/ELF state from the authenticated parent tree
      - [x] Bind a canonical path and ELF validation index from the receipt
      - [x] Merge direct-parent index state with tombstones and changed paths
            and retain periodic independent full-tree validation
      - [x] Scan only the new layer and re-evaluate affected shebang, loader
            and ELF dependency edges against the merged parent index
  - [ ] Publish stable OpenRC/systemd Engine targets and run the real signed E2E
    - [x] Authenticate exact realization plans with an initramfs-embedded
          Ed25519 trust key before accepting dm-verity root hashes
    - [x] Boot signed OpenRC and systemd realization-v3 fixtures with their real
          PID 1 under BIOS and UEFI in the OrbStack QEMU runner

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
