# State filesystem layout

Status: Phase 2 layout version 1 with system-generation sublayout version 1.

## Discovery and boot policy

Volatoo persistent state lives on a filesystem labeled `VOLATOO-STATE`. The
partition table type and partition number are deliberately unspecified: the
initramfs discovers the filesystem metadata, not a fixed disk path. Version 1
uses ext4 as the tested filesystem.

State is optional by default. A machine without the labeled filesystem boots
fully volatile without waiting. Setting `VOLATOO_STATE_REQUIRED=yes` makes the
initramfs wait up to ten seconds and fail into its rescue shell if the state
filesystem is absent. `VOLATOO_STATE=none` explicitly disables discovery.

When found, the state filesystem is mounted read-write, its layout marker is
validated, and the mount is moved into the running root at
`/.volatoo/state`. The persistence and identity directories remain writable,
but the initramfs overlays `/volatoo/system` with a read-only bind mount before
handoff. A discovered filesystem with a missing or unsupported layout marker
is a boot error; silently using an unknown layout could corrupt persistent
data.

The initramfs never creates or formats a state partition. Installation and test
tools must prepare it explicitly.

## Version 1

```text
/volatoo/
├── layout-version        # contains exactly "1"
├── config/               # declarative persistence policy
├── data/
│   ├── bind/             # backing trees for persistent bind mounts
│   ├── identity/         # default machine identity and logs
│   ├── overlay/          # persistent OverlayFS upper/work trees
│   └── sync/             # synchronized path contents
├── snapshots/            # versioned recovery snapshots
└── system/
    ├── layout-version    # contains exactly "1"
    ├── objects/sha256/   # immutable base, layer and metadata objects
    ├── manifests/        # canonical generation manifests
    ├── plans/            # generation-to-boot-plan digest bindings
    ├── realizations/     # generation-to-complete-closure bindings
    ├── signatures/       # trusted-key signatures over realization plans
    ├── pins/             # named generation retention roots
    ├── activations/      # successful live service activation receipts
    ├── compactions/      # verified base-compaction receipts
    ├── staging/          # unpublished temporary objects
    ├── lock               # advisory mutation/GC exclusion lock
    ├── current           # selected generation digest, once activated
    └── previous          # rollback digest, after a second selection
```

Each policy storage key creates its data below the matching policy directory:

```text
bind/<key>/root
bind/<key>/initialized
overlay/<key>/upper
overlay/<key>/work
sync/<key>/
```

A sync key stores content-addressed pristine bases, immutable synchronized
generations, and an atomic `current` pointer:

```text
sync/<key>/
├── current
├── bases/<image-sha256>/{tree,complete}
└── generations/<UTC-timestamp>-<uuid>/{tree,image-id,complete}
```

For `/etc`, the bases and selected generation are inputs to the upgrade-aware
three-way merge. See [`etc-merge.md`](etc-merge.md).

Default machine identity uses:

```text
identity/
├── machine-id
├── ssh-host-keys/{ssh_host_*_key,ssh_host_*_key.pub,complete}
├── logs/
└── logs-initialized
```

These entries are created on first boot with state and do not require a
`persist.conf` policy. Their behavior and opt-out configuration are documented
in [`machine-identity.md`](machine-identity.md).

The system directory is an additive, independently versioned extension. Its
presence does not change the top-level layout marker, so Phase 2 persistence
and identity tools continue to accept the filesystem. `current` and `previous`
contain complete `sha256:<hex>` generation digests. All closure objects, every
exact parent prefix and the canonical manifest are durable before selection
changes. Each layer transaction binds its BuildContext, BuildSpec, package
acquisition and filesystem metadata. Activation supplies an expected
`current` digest, so publication based on a stale generation cannot replace a
newer selection. The boot plan is a derived, content-addressed early-userspace
representation; the canonical JSON manifest remains the generation identity.
Inspection returns the verified boot-plan digest, and host materializers must
present that digest when reconstructing the generation. A pointer changed
between inspection and extraction is therefore rejected. Closure objects are
copied into private storage and hashed there before extraction, so a
subsequent state-store mutation cannot change the root being reconstructed.

Generation v2 stores `org.volatoo.portage-state/v1` in the same
`objects/sha256` namespace and names it from the generation manifest. That
object binds the resulting Portage configuration, world, repository
snapshots, profile and toolchain. Each layered v2 manifest also names its
exact parent generation. Garbage collection follows that parent link and
retains the historical context chain; compaction preserves the PortageState
digest while producing a layer-free generation whose parent is `null`.
Generation v1 manifests remain readable and can enter v2 through one
same-context layer transition. See
[`generation-v2.md`](generation-v2.md).

The running host sees `/.volatoo/state/volatoo/system` read-only. Publication
uses `/usr/libexec/volatoo-update-view`, which takes an exclusive updater lock,
creates a private mount namespace, and makes a non-recursive bind of the
writable state filesystem at `/run/volatoo/update-state`. The public read-only
system submount is not cloned into that private path, so the update command can
publish and atomically switch pointers without making the store writable to
other services. The private mount disappears when the command exits.
Persistence under `/volatoo/data` is unaffected.

This is a mount-namespace safety boundary against ordinary processes and
accidental host writes. A privileged administrator with `CAP_SYS_ADMIN` can
still mount the state block device directly and is outside the threat model.

An optional immutable entry in `realizations/<generation-hex>` names a
content-addressed realization plan. Version 1 binds the generation digest,
exact boot-plan digest, target, BuildContext, complete SquashFS closure,
verified tree digest, Gentoo/FHS contract and pinned builder contract.
Version 2 additionally binds a content-addressed dm-verity hash-tree object,
root hash, deterministic salt and fixed 4096-byte no-superblock geometry.
Version 3 binds an ordered base and FHS update-layer stack. Every record names
the original generation object, exact runtime SquashFS object, and its own
dm-verity object, root hash, salt and geometry. It also binds the
`overlayfs-lowerdir` and `whiteout-char-0-0` composition contracts. Layers
without tombstones are reused directly; transformed layers remain separate
content-addressed objects. Its parent-tree receipt v3 authenticates the
canonical FHS/ELF validation index and a compositional tree-state object that
binds the generation plan, target, BuildContext, validation index and exact
direct-parent state. Receipt v1 and v2 remain readable compatibility formats.
Release mode first verifies a detached Ed25519 signature over the exact small
plan with a public key embedded in the initramfs. SquashFS data and hash-tree
blocks are then authenticated lazily by the kernel. Full object hashing occurs
on publication and `volatoo-generation scrub`, not on every persistent-store
boot.

For realization `sha256:R`, signatures are stored below `signatures/R/`.
Each `<key-sha256>.sig` is an OpenBSD `signify` detached signature over the
exact object at `objects/sha256/R`. Multiple files permit an overlap window
during release-key rotation. See [`release-trust.md`](release-trust.md).

Once a realization is present, boot and host validation require its complete
binding to be valid; a corrupt realized closure or image stack cannot silently
downgrade to layer replay. Realization-v1 entries remain readable with eager
SHA-256, and generations without a realization remain readable for recovery
compatibility.

`current`, `previous`, and every safe file in `pins/` are garbage-collection
roots. Collection recursively marks their manifests, boot plans, realization
plans, signatures, realized closures or image stacks, and all
content-addressed objects referenced by stored metadata. It refuses a corrupt
root and defaults to a dry run. `previous` can be removed only by explicitly
confirming its complete
digest, preserving an intentional rollback window.
Activation and compaction receipts follow the generation they describe and do
not independently retain an otherwise unreachable generation.

`update/volatoo-generation migrate-state --state /mountpoint` creates this
sublayout explicitly and is safe to resume after interruption. It does not
format the filesystem or alter existing persistence data.

The data policy subdirectories and snapshot directory are mode `0700`;
configuration and the layout marker are readable but only root may modify
them. The configuration grammar and policy behavior are documented in
[`persistence-policy.md`](persistence-policy.md). Consumers must reject
unsupported layout versions rather than guessing.

## Test image

The repository can create a regular ext4 image without requiring Linux host
tools:

```sh
scripts/build-state-image.sh
scripts/build-state-image.sh --config persist/example.conf \
  out/volatoo-policy-state.ext4
scripts/build-state-image.sh \
  --identity-config persist/identity.example.conf \
  out/volatoo-custom-identity-state.ext4
```

Docker runs `mkfs.ext4` against a temporary regular file. The script never
accepts or writes to a block device. Its default result is the ignored build
artifact `out/volatoo-state.ext4`.
