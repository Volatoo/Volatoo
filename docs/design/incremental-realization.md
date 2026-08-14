# Incremental authenticated realization

Status: realization v3 is implemented and has passed host contract, BIOS and
UEFI QEMU tests.

## Motivation

Generation publication is already incremental: an ordinary package
transaction adds one immutable FHS-compatible SquashFS layer. Realization v2,
however, reconstructs that generation and recompresses the complete system
closure as one SquashFS before it can be selected. That is appropriate for a
release image or compaction, but it makes a small update pay the compression
cost of the whole Gentoo root.

Realization v3 keeps the NixOS-style property that immutable objects are
published first and a small generation pointer is switched last. It reuses the
existing base and update-layer images, authenticates each one independently
with dm-verity, and composes their normal Gentoo paths as one read-only
OverlayFS lower stack. Only a layer whose tombstones need OverlayFS metadata is
recompressed.

The update still materializes the final tree in a private Linux volume and
validates the Gentoo/FHS and ELF contracts before publication. It skips the
expensive full-closure recompression.

Within that private volume, the materializer snapshots and hashes every boot
plan object once. Incremental realization retains those verified snapshots for
all later transformation and verity work instead of reopening the mutable
state paths and hashing the same base and layers a second time. The temporary
snapshot disappears with the realization workspace.

## Signed plan contract

`VOLATOO_REALIZATION_V3` binds:

- the exact generation, boot plan, target, BuildContext and authenticated
  compositional tree-state digest;
- a content-addressed parent-tree receipt that binds the full FHS/ELF
  validation result to this realization and its exact direct parent;
- `org.volatoo.gentoo-fhs/v1`;
- the `overlayfs-lowerdir` composition and `whiteout-char-0-0` deletion
  contracts;
- one ordered image record for the base and every generation layer;
- each source-object digest and the exact runtime SquashFS digest;
- an independent dm-verity object, root hash, salt and geometry for every
  runtime image; and
- the pinned SquashFS builder contract.

The base record must be first and must reuse the exact generation base object.
Layer records follow the generation order exactly. The host parser rejects
missing, duplicate, reordered, extra or unreferenced images and objects.
Publication hashes every newly supplied object before atomically recording the
realization pointer. An inherited object may skip another eager hash only when
the new authenticated receipt names the exact direct-parent v3 realization and
its complete image record is byte-for-byte identical. Object type, size and
SquashFS shape are still checked; all other cases retain eager verification.

Release mode signs the exact content-addressed plan bytes with OpenBSD
`signify`. The initramfs verifies that signature before accepting any dm-verity
root hash. At boot, the kernel authenticates requested blocks from every
SquashFS independently; early userspace does not eagerly hash complete image
files.

## FHS and deletion semantics

Portage continues installing into a normal staged Gentoo root. A layer contains
paths such as `/usr/bin`, `/usr/lib`, `/etc` and `/var/db/pkg`; packages do not
need a Volatoo-specific prefix or per-package relocation.

Legacy generation tombstones are translated only when necessary:

- a pure deletion becomes an OverlayFS whiteout character device with major
  and minor number zero;
- a non-directory replacement needs no whiteout because the upper layer entry
  hides the older one; and
- a replacement directory receives `trusted.overlay.opaque=y`, preventing
  children of the removed lower directory from merging back into view.

When a whiteout needs a parent directory not present in the changed layer, the
builder copies that directory's exact ownership, mode, ACLs and xattrs from the
validated final tree. It then reproducibly recompresses only that transformed
layer. Layers without tombstones and the base are reused byte for byte.

At runtime, newest layers appear first in OverlayFS `lowerdir`, followed by
older layers and the base. The merged lower is read-only; the normal Volatoo
tmpfs upper remains the disposable writable `/`.

## Lifecycle

`update/realize-generation-incremental-docker.sh` is the ordinary update path.
It:

1. validates the published generation and exact boot plan;
2. materializes and validates the final FHS/ELF tree;
3. transforms only tombstone-bearing layers;
4. reuses direct-parent dm-verity records for byte-identical base and layer
   images, then creates and verifies trees for the remaining images;
5. publishes the realization-v3 plan and any new objects;
6. optionally signs the plan in a network-disabled container; and
7. optionally advances `current` with compare-and-swap.

The initramfs supports v3 in `store-overlay`, legacy `overlay`, and `copy`
modes. `ram-overlay` currently rejects v3 because safely copying, reopening and
releasing a variable image stack needs a separate bounded-memory design.

Garbage collection follows every v3 source, runtime SquashFS and verity object.
`volatoo-generation scrub` remains the explicit eager full-hash operation.
Realization v1 and v2 remain readable; the initramfs never silently downgrades
an invalid realization to legacy layer replay.

The reuse cache is an optimization, not a new trust anchor. The host first
fully validates the direct parent and its v3 realization. The builder then
hashes the content-addressed parent plan and cached hash object again. A record
is reusable only when its source and runtime SquashFS digests are identical,
its sequence, kind and size match the current generation, it has no current
tombstones, and its deterministic salt matches the image digest. Missing or
changed cache objects fail closed. Transformed whiteout layers are regenerated
until their source-to-runtime mapping has a separate authenticated cache
contract. `reuse-report` records the reused and generated image counts for
build diagnostics but is not part of the signed plan.

Every new realization also publishes
`VOLATOO_PARENT_TREE_RECEIPT_V3`. The small receipt binds the generation, boot
plan, target, BuildContext, FHS contract, direct-parent generation, exact
parent realization, a separate content-addressed FHS/ELF validation index and
a compositional tree-state object. The canonical index records path types and modes,
symlinks, executable shebangs, loader configuration and target-ABI `scanelf`
metadata. Its digest and exact size are authenticated by the receipt without
putting the potentially large index on the boot-critical receipt path. V1 and
V2 receipts remain readable as legacy whole-tree and indexed anchors.

`VOLATOO_TREE_STATE_V1` replaces the ordinary flat materialized-tree snapshot.
It binds the exact generation and boot-plan digests, target, BuildContext,
validation-index digest and size, and the exact direct-parent tree state. Its
own digest is the realization's `tree` value. Because the boot plan already
binds every ordered source image and tombstone while realization v3 binds every
runtime image and dm-verity root, this removes redundant per-file content
hashing without dropping a content or semantic binding. A parent-state
mismatch, missing object, changed size or changed digest fails closed during
publication and inspection.

The receipt digest is a `tree-receipt` record in `VOLATOO_REALIZATION_V3`, so
the release signature authenticates the receipt and its index binding without
a second signature format. Publication, inspection, scrub and garbage
collection follow the validation index and tree state as part of the
realization closure.
A changed parent pointer, non-v3 parent, reordered image, metadata mismatch,
missing index or object, changed size, or changed digest fails closed. Runtime
data remains authenticated lazily by the signed dm-verity roots.

V2 supplies the authenticated parent state needed by the incremental
validator. An exact direct child extracts and scans only its new source layer,
producing path, symlink, executable shebang, loader-configuration and target
ABI ELF records. The merger removes tombstoned or replaced parent subtrees,
adds the delta records, and validates mandatory FHS paths, init semantics,
cross-layer shebang and ELF interpreters, loader search directories and every
`DT_NEEDED` edge from the canonical merged index. Unsafe new-layer references
are rejected before the merge. Any malformed, missing, wrong-target or
non-canonical authenticated parent index fails closed.

`VOLATOO_VALIDATION_AUDIT=1` additionally scans the independently
materialized complete tree and requires its index to equal the incremental
result byte for byte. This is retained for periodic audit and CI sampling;
ordinary exact V2 descendants do not repeat the complete FHS/ELF scan.

V3 permits at most 64 update layers. Reaching that limit requires compaction,
which reconstructs the verified tree and publishes a new layer-free base.
`realize-generation-docker.sh` also remains the complete-closure v2 path for
compaction products and release images.

## Validation results

The first two-layer development fixture verified:

- BIOS and UEFI OpenRC boots from a signed realization-v3 stack;
- pure deletion and remove-then-replace FHS behavior;
- exact direct-parent publication reuse of two inherited image records while
  generating only the new tombstone-bearing layer;
- rejection after changing a layer data block; and
- rejection after changing a used base hash-tree block, detached release
  signature or authenticated parent-tree receipt.
- a 134,388-path real OpenRC closure produced an 11,025,508-byte canonical
  validation index, and its direct child reproduced the complete index exactly
  from the authenticated parent, new-layer scan and tombstones;
- directed tests resolve new-layer shebang and ELF dependency edges from the
  parent index, then reject the same closure after its parent provider is
  tombstoned; and
- default and audited signed fixtures produced identical validation indexes
  and realization digests. The complete two-generation fixture took 132
  seconds by default and 170 seconds with the independent full-tree audit on
  the Apple Silicon/amd64-emulation development host.
- receipt v3 produced a 542-byte child tree state with an authenticated parent
  link. Removing two redundant complete-tree snapshots reduced the same
  two-generation signed fixture from 132 to 124 seconds.

Rebuilt signed OpenRC and systemd v3 fixtures passed real PID 1 boots in the
pinned OrbStack QEMU/OVMF runner. Root authentication and handoff took 4
seconds under BIOS and 7 seconds under UEFI. Systemd reached the fixture's
core-service marker in 25 and 27 seconds and serial login in 38 and 40 seconds;
OpenRC reached the marker in 37 and 39 seconds and login in 41 and 43 seconds.
The systemd tail is a 13-second serial-device/getty wait, while OpenRC spends
most of its interval running boot services sequentially. The login remains the
end-to-end Gate and the earlier marker isolates the init/service body.
The validation-index fixture passed in 40 seconds under BIOS and 43 seconds
under UEFI. The later receipt-v3 tree-state fixture passed in 42 seconds under
BIOS and 60 seconds under UEFI; the UEFI serial-login tail varies between
runs, while both reached the authenticated real-PID-1 Gate.

On the same Apple Silicon host using an amd64 Docker builder, the first
incremental realization completed in about 96 seconds and a warm two-layer run
in about 66 seconds. The earlier complete-closure realization took roughly ten
minutes in that cross-architecture environment. These are development
comparisons, not native release-hardware benchmarks.

## Next optimizations

V3 removes whole-closure recompression, complete FHS/ELF scans and flat
complete-tree hashing from ordinary exact descendants, but the materializer
still reconstructs the complete final tree. The next performance work should:

1. avoid extracting inherited images for exact descendants while retaining
   authenticated directory metadata needed by tombstone transformations;
2. authenticate and reuse deterministic tombstone-layer transformations; and
3. add a compaction policy driven by layer count, mount cost and retained
   rollback generations.

Concrete portable bundles for every `/etc/portage` input and the complete
compiler toolchain remain a separate reproducibility hardening task. Their
digests are already part of generation v2, so this does not require another
realization format.
