# In-place whole-image update (A/B slots)

Status: design + implementation in progress. This note specifies the release-media
update path: download a new whole-system image into an inactive slot inside the
state partition, then reboot into it. It is a *different* mechanism from the
granular generation model, not a replacement for it.

## Relationship to the generation model

Volatoo has two update mechanisms. They share cryptographic primitives but solve
different problems, and a machine boots through exactly one of them on any given
boot.

| | Generations (`volatoo-generation`) | Whole-image slots (`volatoo-slot`) |
|---|---|---|
| Unit of update | One package layer realized into a SquashFS layer/closure | One complete release image (kernel + initramfs + root SquashFS) |
| Producer | Local Portage planner + Portage Engine + layer composer | Releng release publication (signed release index + CAS) |
| Boot identity | A content-addressed generation digest selected by `current`/`previous` | A slot (`a` or `b`) selected by boot-state markers |
| Authentication | Ed25519-signed realization plan → dm-verity root hashes → lazy block auth | Ed25519-signed slot manifest → SHA-256 of kernel/initramfs/root |
| Use | Granular, in-place package maintenance without rebuilding the world | Moving wholesale to a new release (kernel + init + root together) |

The two mechanisms are **alternatives**, not layers. A boot path is chosen by the
kernel command line:

- `volatoo.generation=auto` + `volatoo.root=store-overlay` boots the selected
  generation from the system store (`/volatoo/system`).
- `volatoo.root=slot` boots the selected whole-image slot from
  `/volatoo/slots`.

They coexist in the state partition because the state layout is additive. They
must not silently interact: a slot switch does not touch generation metadata, and
a generation selection does not touch slot markers. `volatoo.generation=none` is
set on slot boot paths so the two selection mechanisms can never both claim a
boot. The Ed25519 trust key, the `signify` verifier, and the canonical-JSON digest
convention are shared; only the signed object (realization plan vs. slot manifest)
and the authentication of the large payloads (dm-verity vs. eager SHA-256) differ.

When to use which:

- Use **generations** for ordinary package updates on an installed machine. The
  closure is reconstructed incrementally and boots through dm-verity without
  re-hashing the complete root.
- Use **slots** to move to a new release image in one step: a kernel bump, an
  init-system target change (OpenRC → systemd), or a freshly built release whose
  whole-image digest is published by releng. The payload is verified eagerly by
  SHA-256 at install time, which is acceptable because a release install is a
  rare, whole-image event, not a per-package transaction.

A slot install can *replace* whatever the machine was running (including a
generation-selected boot), and the next boot then uses the slot path. The two
mechanisms do not share a `current` pointer and are not synchronized; an operator
switching between them is switching the boot mode, not "rolling back" one mode
with the other.

## Slot layout inside the state partition

The state partition (`VOLATOO-STATE`) gains an additive `slots/` sublayout with
its own `layout-version`, exactly as `system/` is an independently versioned
extension of the Phase 2 layout. `slots/` version 1:

```text
/volatoo/slots/
├── layout-version        # contains exactly "1"
├── active-a              # empty marker: slot a is the committed, known-good slot
├── active-b              # empty marker: slot b is the committed slot (exactly one active-*)
├── pending-a             # empty marker: slot a is an armed, unproven candidate (at most one pending-*)
├── pending-b             # empty marker: slot b is an armed, unproven candidate
├── tries                 # optional integer: remaining boot attempts for the pending candidate
├── a/
│   ├── kernel            # the release bzImage
│   ├── initramfs         # volatoo-initramfs.cpio.gz
│   ├── root.squashfs     # the Catalyst root image
│   └── manifest.plan     # VOLATOO_SLOT_V1 text plan (signed)
├── b/
│   ├── kernel
│   ├── initramfs
│   ├── root.squashfs
│   └── manifest.plan
└── signatures/
    └── <manifest-sha256-hex>/
        └── <public-key-sha256-hex>.sig   # detached signify signature over manifest.plan
```

### Sizes and expansion

Slot payload sizes are *declared, not reserved*. The slot manifest binds the exact
byte size of `kernel`, `initramfs` and `root.squashfs`, and every consumer
(installer, initramfs, `volatoo-slot verify`) rejects a size mismatch before use.
There is no fixed per-slot partition: the two slots are ordinary files inside the
state ext4, so the state filesystem must simply be large enough to hold two full
images plus the existing state data.

The installer already expands the state partition and filesystem to fill a larger
destination (`scripts/install-volatoo.sh`, `release-media.md`). The slot-aware
install path must size the state partition for `2 × (kernel + initramfs +
root.squashfs) + state data + margin` instead of the single-image state size used
today. The reproducible assembler derives the state-image size from its content
(`scripts/build-state-image.sh`), so a slot-provisioned state image is naturally
larger and the disk assembler's `state_mib` sizing (`release-container`) grows
with it. No per-slot resizing step exists; a slot is either complete and verified
or absent, never partially "grown".

### What lives where

The kernel and initramfs move **out of the ESP** and into the slot directories,
because a whole-image update must be able to change them. The ESP keeps only the
bootloader and its configuration. Slot `a` is the factory default: when no
`active-*` marker exists (a fresh, unprovisioned state), the bootloader falls
back to slot `a`. Provisioning writes both slots and sets `active-a`.

## Download and verification (install time)

The installer reuses the release acquisition path already implemented by the
formal installer (`Volatoo/installer`): it verifies the signed, versioned release
index before acquiring content-addressed media. The slot stage step performs the
same verification and then materializes a slot:

1. Verify the signed release index for the selected channel/architecture/init
   system (releng's detached signature over the index bytes).
2. Resolve the target's `kernel`, `initramfs` and `root.squashfs` CAS objects and
   verify each object's SHA-256 against the index.
3. Construct the slot manifest — a small text plan in the same style as a
   generation realization plan (`VOLATOO_SLOT_V1` header followed by `slot`,
   `channel`, `init-system`, `kernel`, `initramfs`, `rootfs` and optional
   `release-index` records, terminated by `end`). The plan binds the channel,
   init system, release-index digest and the exact digest/size of each blob.
   Sign the exact plan bytes with the release Ed25519 key.
4. Write `kernel`, `initramfs`, `root.squashfs`, `manifest.plan` and the
   detached signature into the **inactive** slot directory, fsyncing each file
   and its directory before the switch.
5. Arm the candidate: create `pending-<inactive>` (and initialize `tries`). This
   is the atomic switch (below).

### Which bytes are authenticated

- **At install time**, every byte that will be written is authenticated twice:
  the signed release index authenticates the CAS object digests, and the object
  SHA-256 check authenticates the bytes against those digests. A wrong, tampered
  or truncated artifact fails before any slot file is written.
- **At boot time**, the Ed25519 signature over the exact `manifest.plan` bytes is
  the trust anchor (the public key is embedded in the initramfs). That signature
  authenticates the digests and sizes of `kernel`, `initramfs` and
  `root.squashfs`. The initramfs then verifies the `root.squashfs` SHA-256 and
  size against the signed plan before mounting it.
- **Not authenticated by the slot manifest**: the `active-*`, `pending-*` and
  `tries` markers. They are the boot-selection state, and are intentionally
  mutable on disk. Tampering with them can only cause the machine to boot a
  *different validly signed slot* or to fall back to the committed slot; it cannot
  cause an unauthenticated kernel, initramfs or root to run, because those are
  verified against a signed manifest before use.
- **Not re-verified at boot**: the `kernel` and `initramfs` that the bootloader
  has already loaded. Their trust comes from (a) verification at install time and
  (b) the outer boot anchor (Secure Boot signed UKI on UEFI, or trust in the boot
  media on BIOS). This is the same boundary as the release-media "development
  integrity mode": on BIOS there is no firmware anchor, and an attacker who can
  rewrite the boot partition can also replace the kernel, initramfs and embedded
  key. See `release-trust.md`.

## Boot selection

The bootloader reads the slot markers from the state partition and loads the
chosen slot's kernel and initramfs directly. The marker approach uses only GRUB
primitives that cannot fail on file parsing: `search`, `if [ -e ... ]`, `set`,
`linux` and `initrd`.

```text
search --no-floppy --label VOLATOO-STATE --set=stateroot
if [ -e ($stateroot)/volatoo/slots/pending-a ]; then
    set boot_slot=a
elif [ -e ($stateroot)/volatoo/slots/pending-b ]; then
    set boot_slot=b
elif [ -e ($stateroot)/volatoo/slots/active-b ]; then
    set boot_slot=b
else
    set boot_slot=a
fi
linux ($stateroot)/volatoo/slots/$boot_slot/kernel \
    console=tty0 console=ttyS0,115200 \
    volatoo.root=slot volatoo.slot=$boot_slot \
    volatoo.state=LABEL=VOLATOO-STATE volatoo.state-required=yes \
    volatoo.generation=none
initrd ($stateroot)/volatoo/slots/$boot_slot/initramfs
boot
```

Precedence: a pending candidate wins over the active slot; the active slot wins
over the implicit default `a`. The initramfs, given `volatoo.slot=<id>`, verifies
the slot manifest and root, mounts the root SquashFS as a read-only lower, and
composes the same tmpfs overlay upper used by `store-overlay`. On a successful
handoff it publishes the slot identity below `/.volatoo/` so a late-boot commit
step and the operator can both see which slot is running.

On UEFI with Secure Boot, the per-slot kernel/initramfs are authenticated by a
per-slot signed UKI at `EFI/...` rather than by GRUB loading arbitrary files; the
boot manager selects the UKI for the chosen slot using the same markers. This is
the same outer anchor the unsigned/signed release-media contract already draws.

## Atomic switch and interrupted writes

The switch is a sequence of *idempotent, ordered* marker and file operations, each
fsynced, with the "never a torn pointer" property derived from the marker
precedence rather than from a multi-file atomic rename:

- **Stage (install)**: write slot files into the inactive slot, fsync them and
  their directory. Only then create `pending-<inactive>`. An interruption before
  `pending-*` leaves a complete-or-absent slot but never arms a half-written one,
  because `pending-*` is created last.
- **Commit (after a successful pending boot)**: create `active-<candidate>`,
  then remove `active-<previous>`, then remove `pending-<candidate>`. The
  transient "both active markers" state resolves to the candidate (GRUB checks
  `pending` first, then `active-b`, then `a`); the transient "no pending, both
  active" state resolves to the newer slot. The transient "pending still present
  after active flipped" state re-boots the candidate once more, harmlessly.
- **Fallback (after a failed pending boot)**: remove `pending-<candidate>`.
  `active` is untouched, so the next boot returns to the committed slot.

Interrupted writes to the slot *files* themselves are handled by content
addressing: a truncated `kernel`, `initramfs` or `root.squashfs` fails its digest
or size check at the next `volatoo-slot verify` or boot, and the marker ordering
above guarantees that a partial slot is never the one being selected unless its
`pending-*` marker was written (which happens only after all files are fsynced and
verified).

## Rollback and boot attempt counting

There are two rollback paths, covering different failure windows:

1. **Explicit rollback** (`volatoo-slot rollback`): the operator or a policy
   clears `pending-*` and selects the other slot as active. This is the
   deterministic recovery command and what the QEMU gate exercises.

2. **Automatic fallback**: when a pending candidate fails during early userspace
   (bad manifest signature, digest mismatch, unreadable root), the initramfs
   decrements `tries`, drops `pending-*`, and boots the committed `active` slot in
   the same boot. The default `tries` is `1`, so a single failed candidate boot
   returns to the last good slot without operator action.

The attempt counter is decremented by the initramfs, which has reliable read/write
access to the state partition. This covers every failure the initramfs can
observe. A failure *before* the initramfs runs (a kernel that panics on load, or a
corrupt initramfs) is not observable from early userspace and therefore cannot be
counted there; recovering from that class requires a bootloader- or firmware-
resident counter (for example the `grubenv` boot-counting mechanism or a UEFI
`BootNext` entry). That extension is deliberately out of scope for this contract,
and its absence is mitigated by install-time verification of the kernel and
initramfs digests: an image that verifies before installation but fails to load is
a bit-rot/undetected-corruption case, not a normal update outcome, and is
recovered with the explicit rollback command.

## State data across a slot switch

Slot switches change only the immutable *system image* (kernel, initramfs, root).
The state partition is shared and its `config/`, `data/` and `system/` subtrees
are **not** duplicated or touched by a slot switch. Therefore:

- Machine identity (`machine-id`, SSH host keys), persistent logs, and every
  declared `bind`/`overlay`/`sync` policy continue to point at the same state
  data after the switch.
- The `/etc` three-way merge sees the new slot's pristine image tree as "new",
  the previous slot's tree as "base" (via the recorded `image-id`), and the
  synchronized machine tree as "local"; the existing merge semantics apply
  unchanged across a slot boundary.
- The generation store (`/volatoo/system`) is untouched: generations remain
  installed and selectable, but are simply not selected on a slot boot.

The invariant is the same one the release-media contract already draws: the
writable root is disposable, and everything that must survive a reboot lives in
the state partition, which is shared across slots.

## Failure modes

- **Missing or corrupt slot manifest** → `slot.manifest` / `slot.signature`; the
  slot is rejected, and a pending candidate falls back to `active`.
- **Root SquashFS digest or size mismatch** → `slot.root-integrity`; same
  fallback.
- **No verifiable slot at all** (both slots absent/corrupt) → `slot.unbootable`,
  matching the generation model's `generation.unbootable`.
- **Torn active markers** (both or neither present) → resolved by marker
  precedence; both resolves to `b` then `a`, neither resolves to the default `a`.
- **State partition missing** with `volatoo.state-required=yes` → `state.not-found`
  before slot selection; slot boot requires state.

## Trust boundary summary

```text
Secure Boot signed UKI (UEFI) / trusted boot media (BIOS)
  -> per-slot kernel + initramfs (with embedded release Ed25519 key)
  -> Ed25519 signature over exact slot manifest bytes
  -> SHA-256 digests + sizes of kernel, initramfs, root.squashfs
  -> read-only root SquashFS lower + disposable tmpfs upper
```

Signed rollback is intentional, exactly as in the generation model: a user may
select any still-validly-signed slot, and replay prevention of an old-but-signed
release requires separately protected monotonic state (TPM/authenticated UEFI),
which is out of scope.
