# Generation v2 and Portage desired state

Status: implemented for manifest validation, publication, planning gates,
binary-only layer composition, activation, garbage collection, compaction and
boot realization. Generation v1 remains a read-compatible legacy format.

## Problem

Generation v1 binds one BuildContext to a base and its complete ordered layer
list. Every appended layer must reuse that context. This is safe for package
transactions whose Portage inputs never change, but it cannot express a
repository update, profile revision, Portage configuration change, toolchain
transition or resulting world-set change.

The layer transaction records its resulting world digest, but generation v1
does not make that result the desired state of the generation. Reconstructing
the files is therefore possible while answering “which Portage state should
this generation represent?” is not.

## Contracts

`org.volatoo.portage-state/v1` is a canonical content-addressed object:

```text
PortageState =
    hard target
  + Portage configuration digest
  + world digest
  + sorted repository names, revisions and tree digests
  + profile identity and revision
  + Portage version and toolchain digest
```

`org.volatoo.generation/v2` retains the base and ordered FHS-compatible
SquashFS layers and adds:

- `portage_state_digest`, which identifies the resulting desired state;
- `parent_generation_digest`, which identifies the exact generation extended
  by the latest layer;
- the BuildContext used to resolve and install the latest transition.

The parent is `null` only for a layer-free base or compacted generation. A
layered v2 generation must name a parent. The candidate must contain exactly
the parent base and layers plus one new layer.
Version 2 permits at most 256 layers; a longer chain must be compacted. This
keeps recursive parent validation and early operational costs bounded.

The explicit parent link replaces the v1 assumption that every historical
prefix can be reconstructed by truncating one manifest that has one immutable
BuildContext. Each v2 parent retains its own context and PortageState, so
history can change desired inputs without weakening provenance.

## Transition rules

For a transition from parent `P` using BuildContext `C`, transaction `T` and
result `G`:

1. `P` must already be a completely valid published generation.
2. The hard target and base root in `C` must match `P`.
3. When `P` is v2, `C.world_digest` must equal the world digest in the parent
   PortageState. Resolution therefore starts from the recorded parent state.
4. Repository, profile, configuration and toolchain fields in the new
   PortageState come from `C`.
5. The resulting world digest comes from the clean binary-only staging result
   recorded by `T`, not from a caller prediction.
6. `G.parent_generation_digest` must equal the canonical digest of `P`.
7. `G.portage_state_digest` must equal the canonical digest of the exact
   PortageState derived in steps 3–5.
8. `G` must append exactly the filesystem layer bound by `T`.

A v1 generation may be extended by one v2 transition only while keeping the
same BuildContext. Later v2 transitions may change the modeled Portage state.
This gives existing stores an explicit, non-destructive migration path.

## Store and lifecycle

PortageState is stored under the existing object namespace:

```text
/volatoo/system/objects/sha256/<portage-state-digest>
```

No mutable state directory or new layout version is required. Publication
verifies the latest transaction and the complete published parent. Garbage
collection follows `parent_generation_digest`, so selecting a v2 descendant
retains every required parent and its provenance objects. Compaction produces
a layer-free v2 generation with a new base BuildContext, preserves the exact
PortageState digest and resets the parent to `null`.

Boot plans keep their existing format. They bind the complete canonical
generation digest, and that digest transitively binds PortageState and the
parent relationship. Realization signatures therefore authenticate v2
desired state without adding mutable early-boot parsing.

## Scope boundary

Generation v2 makes state transitions explicit and content-addressed. It does
not define a package-level non-FHS store: Portage still installs into a normal
Gentoo root. Volatoo may realize that generation either as one authenticated
read-only closure for release/compaction or as an independently authenticated
base and FHS layer stack for ordinary updates. Both forms preserve the same
normal runtime paths and bind the complete generation identity.

See [`incremental-realization.md`](incremental-realization.md) for realization
v3 composition and tombstone semantics.

Repository revisions and the active Portage version are checked by the
planner today, and the resulting world file is measured after staging.
Producing and applying portable canonical bundles for every
`/etc/portage` configuration input and complete compiler toolchain closure is
a separate builder-input hardening step. Their digests are already mandatory
generation identities, so that work can add concrete objects without another
generation-format change.
