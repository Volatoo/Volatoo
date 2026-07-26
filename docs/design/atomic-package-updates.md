# Atomic package updates

Status: Phase 3 implementation; P3U-0 through P3U-4 and the local P3U-5
operations are implemented. The real Portage Engine infrastructure Gate
remains pending.

## Goals

Volatoo must keep Gentoo's normal package flexibility without turning every
package change into a complete operating-system image rebuild. A package
transaction may use locally built packages or trusted packages from a Gentoo
binhost, but the persistent result must be an immutable, rollback-capable
system generation.

This design has four goals:

1. Build a small system layer for an ordinary package transaction.
2. Accept local and remote binpkgs through the same verification path.
3. Make the selected generation an atomic state update.
4. Keep Portage authoritative for USE, ABI, dependency and SLOT decisions.

Rebuilding the base image remains useful for releases and compaction. It is
not the normal unit of package maintenance.

## Ownership boundary

Volatoo and Portage Engine have separate responsibilities.

| Component | Responsibility |
|---|---|
| Portage | Resolve the requested atoms against the target profile, effective USE configuration, installed VDB and repository state |
| Portage Engine | Build, verify, sign, promote and serve reusable Gentoo binpkgs |
| Volatoo update client | Record desired state, choose a package source, install the transaction into a staged target and compose a system layer |
| Volatoo boot lifecycle | Select, verify, materialize and roll back immutable generations |
| Service manager | Activate service-level changes gracefully when policy allows it |

Portage Engine does not publish a complete Volatoo operating-system image for
each package request. Volatoo consumes a verified binpkg closure and owns the
system-generation format.

## Compatibility model

Compatibility has two levels.

### Hard target

The hard target selects a binhost namespace and builder image. These fields
must match:

- architecture and `CHOST`;
- libc;
- multilib mode and enabled ABI family;
- init system and parent profile family;
- immutable profile repository revision;
- Gentoo and Volatoo repository revisions;
- base image generation and rootfs digest;
- toolchain baseline;
- CPU compatibility class.

### Init-system selection

OpenRC and systemd are equally supported hard targets:

```text
volatoo/amd64/glibc/openrc/23.0/base-v1
volatoo/amd64/glibc/systemd/23.0/base-v1
```

The user selects the init-system target when installing an image or selecting
a complete base generation. Each target has its own matching Gentoo stage3,
profile, base image, binhost index, verifier image and QEMU test lane.

An OpenRC system layer must never be appended to a systemd generation, or the
reverse. Changing init systems is a base-generation migration rather than an
ordinary package transaction: PID 1, service packages, default USE, boot
configuration and dependency closure all change together.

Portable persistent data such as home directories and application data may be
reused according to policy. Init-specific service enablement and configuration
are migrated explicitly and are not blindly overlaid across the two targets.
The first release may require reinstalling or selecting a fresh base to change
init systems; an automated cross-init migration is not required for initial
feature parity.

Feature parity requires both targets to pass the same lifecycle gates:

- verified stage3 and repository inputs;
- Catalyst image build and manifest production;
- BIOS and UEFI boot to a usable console;
- machine identity and persistence restore;
- manual and shutdown persistence sync;
- package planning, binary-only layer installation and rollback;
- corruption and interrupted-publication recovery.

The initramfs continues to execute the selected image's `/sbin/init`; it does
not need to implement OpenRC or systemd policy. Init-specific service units,
shutdown ordering and QEMU success detection belong to their respective image
and test lanes.

Public binpkgs must use a declared CPU baseline. Builds made with an
unconstrained `-march=native` belong to a machine-local or CPU-specific target
and must not enter a generic release binhost.

### Immutable BuildSpec

Package-level variation belongs in an immutable BuildSpec instead of creating
a new builder image for every combination. It records:

- requested atoms and sets;
- resolved CPV, repository, SLOT/subslot and dependency closure;
- effective USE for every package in the closure;
- keywords, masks, licenses and relevant `package.*` configuration;
- compiler and linker settings;
- Portage version;
- the source build context digest.

The effective USE set is the value after profile defaults, force/mask rules,
`package.use`, `IUSE`, `USE_EXPAND` and ABI settings have been applied. A raw
global `USE` string is not a compatibility key.

The digest is an early cache and query key. It is not a replacement for
Portage's resolver. Before a binpkg is accepted, a clean target must resolve
and install the requested closure with binary-only mode,
`--binpkg-respect-use=y` and `--binpkg-changed-deps=y`.

## Package sources

All package sources feed the same staged installation:

1. A promoted Portage Engine release binhost.
2. A machine-local PKGDIR.
3. A local isolated build.
4. An explicitly requested Portage Engine remote build.

A local build runs inside a root reconstructed from the selected Volatoo
generation. It does not inherit unrecorded drift from the live tmpfs root.
Distfiles, compiler cache and the local PKGDIR may be mounted into the builder,
but the target VDB, profile and repository revisions come from the build
context.

Locally produced artifacts are trusted only by that machine by default. An
upload to Portage Engine enters quarantine and must pass server-side policy,
clean installation verification and promotion. A local builder never receives
the release signing key.

Portage's multi-instance binpkg layout may retain multiple builds of the same
CPV. Hard targets use separate binhost indexes; compatible USE and dependency
variants may coexist inside one target.

### Acquisition contract

`org.volatoo.package-source-catalog/v1` declares ordered local and remote
sources for exactly one hard target. Source IDs are canonical and priority
controls selection. A local source is an absolute PKGDIR; a remote source is a
credential-free HTTPS binhost. Both paths must end in the complete target ID,
so OpenRC and systemd indexes cannot be substituted accidentally.

Remote sources always require GPKG signatures and an exact set of trusted
primary-key fingerprints. A machine-local source may instead use the
`machine-local` policy, but that trust never upgrades the package to a
publishable artifact. Redirects are rejected and index and artifact reads are
bounded.

There are two explicit compatibility claims:

- `volatoo-attested` requires the GPKG to embed the target ID, build-context
  digest and complete package-build digest.
- `portage-resolved` accepts a standard signed Portage GPKG after checking
  CPV, repository, SLOT/subslot, EAPI, CHOST, USE/IUSE, build flags, metadata,
  archive Manifest and content digest. It does not claim that a standard
  package contains complete Volatoo build provenance.

Portage records effective dependency metadata in a built GPKG, so it is not
safe to compare those strings byte-for-byte with the conditional ebuild
expressions in a BuildSpec. For `portage-resolved`, P3U-3 therefore performs a
fresh binary-only resolution in the pristine target using
`--binpkg-respect-use=y` and `--binpkg-changed-deps=y`. Full byte-level binding
of the original dependency expressions is available only through the
`volatoo-attested` package-build digest.

Successful acquisition writes each package to
`sha256/<digest>.gpkg.tar` without overwriting an existing object, then emits
`org.volatoo.package-acquisition/v1`. The receipt binds every acquired or
missing BuildSpec sequence to the context, BuildSpec and source-catalog
digests. Missing packages fail by default. `local-build` and `remote-build`
are explicit caller choices that produce an incomplete receipt for the build
or submission workflow; acquisition never submits work implicitly.

## Transaction and layer composition

An update operates on a complete transaction, not an isolated package file:

1. Reconstruct the current pristine generation in a private staging root.
2. Ask Portage to resolve the desired atoms and complete dependency graph.
3. Acquire or build every required binpkg.
4. Install using binary-only mode into a second clean staging root.
5. Validate the resulting VDB, world file, preserved libraries and dependency
   graph.
6. Capture the filesystem delta, package database changes, configuration
   defaults and removals.
7. Write the changed files to a read-only SquashFS system layer.
8. Write removals to a canonical tombstone object.
9. Create a new generation manifest that appends the layer.
10. Publish all objects before atomically advancing the `current` pointer.

Tombstones are applied before the corresponding layer so that a transaction
may remove an old path and create a replacement at the same location.
Protected configuration follows the existing `/etc` three-way merge policy;
package defaults and local administrator state are not collapsed into one
unreviewable tree.

## Generation model

A generation is a small immutable manifest:

```text
Generation = hard target + base object + ordered system layers
```

Objects are addressed by SHA-256. The manifest digest is the generation
identity. System-generation sublayout version 1 is:

```text
/volatoo/system/
├── layout-version
├── objects/sha256/<digest>
├── manifests/<generation-digest>.json
├── plans/<generation-digest>
├── staging/
├── current
└── previous
```

`current` and `previous` contain manifest digests, not mutable directory
names. Publication writes and verifies objects and the manifest first, then
atomically replaces the pointer. Garbage collection retains the selected
generation, rollback generations, pinned generations and every referenced
object.

The top-level Phase 2 state layout remains version 1. Enabling generation
storage is an explicit, resumable additive migration and carries its own
system sublayout marker, so existing persistence consumers remain compatible.

## Activation policy

Generation publication and live service activation are separate operations.

- The new generation becomes the default for the next boot atomically.
- A normal package update does not require rebuilding the base image.
- A service may be activated immediately using a declared service policy:
  config test, graceful reload, restart or blue/green handoff.
- Core runtime, libc, init, kernel and unknown file ownership changes default
  to next-boot activation.

Volatoo does not claim that an arbitrary process can atomically switch its
already mapped libraries. Service-aware activation provides no-reboot updates
where the application has a safe mechanism; reboot remains the consistency
boundary for the whole host.

## Portage Engine integration contract

Portage Engine resolves stable Volatoo targets such as:

```text
volatoo/amd64/glibc/openrc/23.0/base-v1
volatoo/amd64/glibc/systemd/23.0/base-v1
```

The server-side catalog binds that ID to the profile revision, repository
revisions, image generation, rootfs manifest, mirror bundle and builder
template. A request contains the target ID and immutable BuildSpec, not a
client-selected builder or mutable repository URL.

The initial integration requires:

1. Matching Volatoo OpenRC and systemd targets in the Portage Engine profile
   registry.
2. A canonical BuildSpec and digest returned by the local planner.
3. A query API keyed by hard target and BuildSpec digest.
4. Target-separated binhost indexes with multi-instance retention.
5. A verifier based on the same Volatoo generation as the request.
6. Staging, isolated signing and atomic promotion.
7. Signed provenance binding the binpkg closure to its complete build context.

`update/volatoo-engine` implements the client-side control-plane adapter. An
operator-reviewed `org.volatoo.portage-engine-target/v1` binding maps one
BuildSpec hard target to the server-owned profile, repository set, resource
class, immutable builder image and mirror bundle. It also pins the exact
`/binpkgs/<complete target_id>` namespace. OpenRC and systemd therefore have
different bindings even when all package-level choices happen to match.

The adapter translates exact CPVs, effective USE/IUSE, accepted keywords and
compiler/linker flags into Portage Engine's `LocalBuildRequest` and
`ConfigBundle`. Submission is idempotent over the BuildSpec, target binding
and exact request. A successful status is accepted only when its resolved
profile, architecture, repositories, resource class, builder image and mirror
bundle match the binding, and every reported artifact is below its
target-specific binhost path.

The resulting `org.volatoo.portage-engine-job/v1` receipt binds the BuildSpec,
target binding, exact submitted request and resolved job provenance. It does
not replace `org.volatoo.package-acquisition/v1`: after server-side
verification, signing and promotion, `volatoo-acquire` independently consumes
the standard signed `Packages` index and GPKGs through the same data path as
any release binhost.

Required Portage FEATURES remain operator policy. The client proves that every
package in the BuildSpec matches the reviewed target binding, but does not send
FEATURES as an overridable build variable. Portage Engine must enforce them in
the selected immutable target and retain them in package metadata for the
normal acquisition compatibility check.

## Delivery plan

### P3U-0 — Contracts

- Define strict versioned build-context and generation manifests.
- Treat OpenRC and systemd as distinct hard targets.
- Provide canonicalization, validation and digest tooling.
- Add fixtures and negative tests.

### P3U-1 — Local planner

- [x] Read the selected Volatoo build-context and generation identity.
- [x] Run Portage resolution against the selected pristine root.
- [x] Detect the active init target and reject cross-target package sources.
- [x] Emit a canonical, reviewable BuildSpec and package-source query.
- [x] Fail closed on unpinned repositories or an incompatible target.

The P3U-1 implementation is `update/volatoo-plan`. Portage does not currently
offer a stable machine-readable resolver output, so Volatoo does not parse
`emerge --pretend` terminal text. A versioned adapter calls the Portage 3.0
resolver in-process and converts its result into
`org.volatoo.build-spec/v1`. The adapter is private implementation detail; the
canonical manifest is the interface consumed by later phases.

The planner checks the exact Portage version, target architecture, CHOST,
libc, multilib ABI set, active profile revision, installed init package and
configured repository revisions before resolving. A repository snapshot must
carry `metadata/timestamp.commit` or `.volatoo-revision`; a Git repository must
be clean. Extra, missing, dirty or differently pinned repositories are
rejected.

Normal atom requests intentionally do not imply a deep `@world` update.
Resolution includes the complete consistency graph and build
dependencies for the requested transaction. This keeps a small request small
while still allowing Portage to select every binpkg needed to build and stage
that transaction. Whole-system maintenance is an explicit request and later
produces a larger layer under the same protocol.

### P3U-2 — Package acquisition

- [x] Configure target-specific local and HTTPS binrepos.
- [x] Keep OpenRC and systemd binhost indexes and artifacts isolated.
- [x] Preserve and deterministically select multi-instance binpkgs.
- [x] Implement explicit local-build and remote-build choices.
- [x] Verify hashes, GPKG signatures, trust roots and Portage compatibility.

The P3U-2 implementation is `update/volatoo-acquire`. It consumes a BuildSpec
and source catalog, selects the highest-priority compatible instance, verifies
the downloaded GPKG and publishes it into a content-addressed store. Selection
is deterministic: sources are considered by descending priority and then ID;
multiple instances use `BUILD_TIME`, `BUILD_ID` and path as tie-breakers.

Portage Engine's existing standard `Packages` index and GPKG artifacts are
format-compatible with the `portage-resolved` path. Integration still requires
Portage Engine to publish target-separated Volatoo namespaces and release
signatures. Complete `volatoo-attested` provenance additionally requires the
three Volatoo metadata fields described above.

### P3U-3 — Layer composer

- [x] Define changed-path, tombstone and layer-transaction contracts.
- [x] Add a disposable Docker staging path with binary-only Portage options.
- [x] Capture files, VDB, world, ownership, ACLs, xattrs and tombstones.
- [x] Add deterministic SquashFS composition in a separate container.
- [x] Pass the real OpenRC/systemd Docker installation matrix.
- [x] Reconstruct and verify the complete generation before publication.

The initial implementation is `update/volatoo-layer`, orchestrated by
`update/compose-layer-docker.sh`. Before mutation it verifies the complete
acquisition and the active target/profile/repository context. Only the
acquired GPKGs are exposed through a temporary PKGDIR; both the pretend pass
and installation use `--usepkgonly`, `--binpkg-respect-use=y` and
`--binpkg-changed-deps=y`.

Filesystem snapshots exclude container mounts and volatile Portage caches,
logs and temporary directories. Changed paths are copied with numeric
ownership, ACLs and xattrs. Removed subtrees become canonical tombstones.
SquashFS creation is isolated in a minimal compressor image and normalizes
filesystem and image timestamps. Finalization appends one candidate layer but
does not publish or select it.

The staging tree and compressor exchange data through a Docker volume so that
Linux ownership, ACLs and xattrs never pass through a macOS bind mount. The
OpenRC/systemd integration matrix extracts each finished layer, proves that a
second compression is byte-identical, applies it to a fresh matching stage3
root and verifies both the installed payload and Portage VDB.

### P3U-4 — Atomic generation boot

- [x] Add the versioned system-generation state sublayout.
- [x] Verify and materialize the selected base plus ordered layers in initramfs.
- [x] Atomically select `current`, retain `previous` and expose rollback.
- [x] Test interruption and corruption paths in both OpenRC and systemd QEMU
  lanes.

`update/volatoo-generation` publishes a generation only after its complete
context, base, layer, tombstone and transaction closure has been verified and
stored by SHA-256. It derives a strict, content-addressed early-boot plan from
the canonical generation manifest, then publishes the immutable manifest and
plan before changing either selection pointer.

Selection writes `previous` first and atomically replaces `current` last. A
power loss between those operations therefore leaves the old current
generation bootable. Rollback performs the same safe ordering in reverse.
The initramfs verifies the selected manifest, boot plan and every referenced
object before mounting the base or applying a tombstone. If automatic current
verification fails, it verifies and boots `previous`; explicit digest or
`previous` selections fail closed instead of silently choosing another
generation.

The top-level Phase 2 state layout remains version 1 for compatibility with
already-built persistence and identity tools. Generation storage has its own
`/volatoo/system/layout-version` marker. This additive migration avoids making
a legacy recovery boot unusable merely because generation support was enabled.

The QEMU fixture uses two layers so it exercises ordinary additions, removals
and removal followed by replacement. OpenRC and systemd both pass BIOS and
UEFI normal selection, corrupt-current fallback and interrupted-selection
boots with their real PID 1.

### P3U-5 — Operations

- [x] Add service activation policies and health checks.
- [x] Add pinning, inspection, rollback and garbage collection.
- [x] Compact long layer chains into a new base without changing desired state.
- [x] Add the canonical Portage Engine adapter and mocked control-plane Gate.
- [ ] Exercise a real local build, release binhost and Portage Engine end to
  end.

`volatoo-activate` handles the deliberately narrow live-activation path. The
selected candidate must append exactly one layer to the generation recorded by
the running root. A canonical, target-specific policy must cover every package
and every effective changed or removed path. Updates touching libc, an init
system, a kernel or core boot/library paths fail closed to next-boot
activation.

The tool snapshots the affected live paths, applies the verified layer, runs
configuration checks, asks OpenRC or systemd to reload/restart the declared
service (or runs an explicit external handoff), and then runs bounded health
checks. Failure restores the paths, invokes the rollback action and selects
the running generation again. Success advances the live generation marker and
writes an immutable activation receipt. This is service-level continuity, not
a claim that already-running arbitrary processes change their mapped
libraries atomically.

Generation operations share an advisory mutation lock. Named pins, `current`
and `previous` form the GC root set. Collection recursively retains boot
closure and stored provenance objects, refuses invalid roots and is dry-run by
default. Dropping `previous` requires its exact digest as confirmation.

Docker compaction reconstructs only verified immutable objects, applies all
tombstones and layers in order, and builds a layer-free generation with the
same target and build context. It compares content, file types, numeric
ownership, modes, link metadata, ACLs and xattrs before publication and
records a compaction receipt. The source remains `previous` when the compacted
generation is selected, so old layers are collectible only after the operator
pins them or explicitly gives up that rollback point.

## Non-goals for the first implementation

- Automatically submitting a remote build whenever `emerge` misses a binpkg.
- Giving an untrusted builder a release signing key.
- Treating the live writable tmpfs root as a reproducible build input.
- Publishing arbitrary local USE variants to the shared release channel.
- Claiming root-wide live activation for arbitrary package transactions.
