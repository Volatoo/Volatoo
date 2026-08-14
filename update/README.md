# Volatoo update contracts

This directory contains the first implementation of the atomic package update
design in `docs/design/atomic-package-updates.md`.

## Manifest types

`org.volatoo.build-context/v1` identifies the immutable environment in which
Portage resolves and builds a package transaction. The init system is part of
this hard target: OpenRC and systemd use different target IDs, base images and
package namespaces.

`org.volatoo.build-spec/v1` is the canonical result of a local Portage
resolution. Package order is significant. Each entry records the exact CPV,
repository, SLOT/subslot, source type, effective USE, IUSE, accepted keywords
and licenses, build flags and dependency metadata.

`org.volatoo.package-source-query/v1` is the lookup key used by a local PKGDIR
or Portage Engine. It binds the hard target and build context to the canonical
BuildSpec digest.

`org.volatoo.package-source-catalog/v1` declares local PKGDIR and remote HTTPS
binhost sources for one hard target, including priority, signature policy,
trusted GPG fingerprints and compatibility mode.

`org.volatoo.package-acquisition/v1` is the receipt for the complete binary
package closure. It binds every BuildSpec sequence to a verified
content-addressed GPKG or to an explicit local-build/remote-build action.

`org.volatoo.layer-paths/v1` and `org.volatoo.tombstones/v1` record the
canonical filesystem delta. `org.volatoo.layer-transaction/v1` binds that
delta and its SquashFS object to the parent generation, package acquisition
and resulting Portage world state.

`org.volatoo.generation/v1` identifies one base SquashFS and an ordered list of
system layers under one immutable BuildContext. It remains readable for
existing stores.

`org.volatoo.portage-state/v1` identifies the resulting Portage configuration,
world set, repository snapshots, profile and toolchain.
`org.volatoo.generation/v2` binds that desired state and the exact parent
generation to the base and ordered FHS-compatible layers. A v2 descendant may
therefore change Portage inputs without rewriting its historical parents.
The generation manifest digest remains the generation identity.

`org.volatoo.portage-engine-target/v1` is an operator-reviewed binding from a
Volatoo hard target to a Portage Engine profile, repository set, immutable
builder image, mirror snapshot and target-separated binhost path.
`org.volatoo.portage-engine-job/v1` records the request and resolved builder
provenance returned by one successful remote build.

The JSON schemas document the wire format:

- `schemas/build-context-v1.schema.json`
- `schemas/build-spec-v1.schema.json`
- `schemas/generation-v1.schema.json`
- `schemas/generation-v2.schema.json`
- `schemas/layer-paths-v1.schema.json`
- `schemas/layer-transaction-v1.schema.json`
- `schemas/package-acquisition-v1.schema.json`
- `schemas/package-source-catalog-v1.schema.json`
- `schemas/package-source-query-v1.schema.json`
- `schemas/portage-engine-job-v1.schema.json`
- `schemas/portage-engine-target-v1.schema.json`
- `schemas/portage-state-v1.schema.json`
- `schemas/tombstones-v1.schema.json`
- `schemas/activation-policy-v1.schema.json`
- `schemas/activation-receipt-v1.schema.json`

`volatoo-manifest` adds semantic checks that JSON Schema cannot conveniently
express, including sorted repository input, stable target namespaces, unique
layer identities and cross-manifest references.

## Canonical form and digest

Canonical JSON uses:

- UTF-8;
- lexicographically sorted object keys;
- no insignificant whitespace;
- unmodified array order;
- one trailing newline.

The identity is the lowercase SHA-256 of those exact bytes, prefixed with
`sha256:`. Repository sources and ABI values must be sorted before a context is
accepted. Layer order remains significant.

The tool rejects duplicate JSON keys, unknown fields, unsupported schemas,
invalid digests, booleans used as integers and manifests larger than 1 MiB.
It depends only on the Python standard library.

## Usage

```sh
update/volatoo-manifest validate \
  update/examples/build-context-v1.json

update/volatoo-manifest canonicalize \
  update/examples/build-context-v1.json

update/volatoo-manifest digest \
  update/examples/build-context-v1.json

update/volatoo-manifest verify-generation \
  update/examples/generation-v1.json \
  update/examples/build-context-v1.json

update/volatoo-manifest verify-generation \
  update/examples/generation-v2.json \
  update/examples/build-context-v1.json \
  update/examples/portage-state-v1.json

update/volatoo-manifest verify-generation \
  update/examples/generation-systemd-v1.json \
  update/examples/build-context-systemd-v1.json

update/volatoo-manifest verify-build-spec \
  update/examples/build-spec-v1.json \
  update/examples/build-context-v1.json

update/volatoo-manifest verify-package-source-query \
  update/examples/package-source-query-v1.json \
  update/examples/build-spec-v1.json \
  update/examples/build-context-v1.json

update/volatoo-manifest verify-acquisition \
  update/examples/package-acquisition-v1.json \
  update/examples/build-spec-v1.json \
  update/examples/build-context-v1.json \
  update/examples/package-source-catalog-v1.json
```

`verify-generation` confirms that the target, context digest and base rootfs
digest agree. For v2 it also verifies the exact content-addressed
PortageState. `volatoo-generation inspect` verifies the complete stored
closure and returns its boot-plan digest. The Docker materializer requires
that exact digest, rejects a changed generation-to-plan pointer, then hashes
private snapshots of the manifest, boot plan and every referenced object
before reconstructing the root only from those verified snapshots.

## Local Portage planner

`plan-generation-docker.sh` is the host entry point. It resolves and validates
an already-published generation, verifies that it names the supplied
BuildContext, reconstructs its base and ordered layers into a private Docker
volume, and chroots into that exact root before invoking `volatoo-plan`.
Planning therefore cannot silently fall back to a caller-selected stage3 or
the mutable live tmpfs root. A v1 parent requires the same context; a v2
parent permits a new context only when its input world matches the parent
PortageState. The reconstructed root supplies Portage's Python
modules and installed VDB; every repository is mounted at the revision named
by the build context.

Repository revisions are read from `metadata/timestamp.commit`, a
`.volatoo-revision` snapshot marker, or a clean Git checkout. The planner
rejects a missing marker, a dirty Git tree, an extra repository or a revision
mismatch. It also rejects mismatched Portage, ARCH, CHOST, libc, ABI, profile
revision and init system. Init detection uses both the profile chain and the
installed OpenRC/systemd package, so changing only a target ID cannot bypass
the check.

Example:

```sh
update/plan-generation-docker.sh \
  --state /.volatoo/state \
  --generation current \
  --build-context /run/volatoo/build-context.json \
  --output /var/tmp/build-spec.json \
  --query-output /var/tmp/package-source-query.json \
  app-misc/jq
```

Additional immutable repositories use
`--repository NAME=/absolute/snapshot`. `volatoo-plan` remains the internal
resolver executed inside the reconstructed root.

The default request is a oneshot transaction. Add `--select` when the requested
atoms should enter the world set. Atoms are resolved with a complete graph and
build dependencies, but the planner does not implicitly perform a deep
`@world` update. A small request therefore produces only the package closure
needed for that transaction.

Portage currently exposes no stable machine-readable resolver output. The
planner uses the installed Portage 3.0 `_emerge.depgraph` API behind the
versioned `portage-3.0-depgraph-v1` adapter. The exact Portage version must
match the build context, and other Portage API families fail closed until an
adapter is added. Human-oriented `emerge --pretend` output is never parsed as
a protocol.

## Package acquisition

`volatoo-acquire` runs inside the same selected Gentoo target family as the
planner. It reads a standard Portage `Packages` index from a target-specific
local PKGDIR or HTTPS binhost, selects compatible multi-instance GPKGs and
writes verified artifacts to a SHA-256 content-addressed store.

Remote sources require GPKG signatures and an exact trusted primary-key
fingerprint set. Local sources may be declared `machine-local`. A
`volatoo-attested` source must embed the target, build-context and package
digests in GPKG metadata. A standard `portage-resolved` package is checked
against CPV, repository, SLOT, EAPI, CHOST, USE/IUSE, build flags and signed
GPKG metadata; its dependency closure is re-resolved in binary-only mode by
the P3U-3 installer.

Example inside the selected root:

```sh
update/volatoo-acquire \
  --build-context /run/volatoo/build-context.json \
  --build-spec /var/tmp/build-spec.json \
  --source-catalog /etc/volatoo/package-sources.json \
  --store /volatoo/system/objects \
  --receipt /var/tmp/package-acquisition.json
```

Missing packages fail closed by default. `--missing-action local-build` and
`--missing-action remote-build` emit an incomplete receipt and exit with
status 2; they do not build or submit work automatically.

## Portage Engine adapter

`volatoo-engine` converts the canonical BuildSpec into Portage Engine's
`LocalBuildRequest` and `ConfigBundle`. It does not let the client select an
arbitrary builder: the separate target binding pins the approved profile,
repository IDs and names, resource class, image digest, mirror bundle digest,
required Portage FEATURES and binhost namespace.

The example target bindings contain illustrative digests. Production bindings
must be generated from and reviewed against Portage Engine's stable server
catalog. Their binhost path is exactly `/binpkgs/<complete target_id>`, which
keeps OpenRC and systemd artifacts isolated.

```sh
update/volatoo-manifest canonicalize \
  update/examples/build-context-v1.json > /var/tmp/build-context.json
update/volatoo-manifest canonicalize \
  update/examples/build-spec-v1.json > /var/tmp/build-spec.json

update/volatoo-engine render \
  --build-context /var/tmp/build-context.json \
  --build-spec /var/tmp/build-spec.json \
  --engine-target update/examples/portage-engine-target-openrc-v1.json \
  --output /var/tmp/portage-engine-request.json

update/volatoo-engine submit \
  --request /var/tmp/portage-engine-request.json \
  --build-spec /var/tmp/build-spec.json \
  --engine-target update/examples/portage-engine-target-openrc-v1.json \
  --server https://portage-engine.example \
  --api-key-file /run/secrets/portage-engine-api-key \
  --receipt /var/tmp/portage-engine-job.json
```

`submit` waits for a terminal job result. Its idempotency key covers the
BuildSpec, target binding and exact request, so a changed builder generation
does not accidentally reuse an older job. It accepts credentials only from a
regular file inaccessible to group and other users, and rejects any resolved
profile, repository set, builder image or mirror snapshot that differs from
the target binding. HTTP is disabled except for an explicit `--allow-http`
trusted-LAN/test invocation.

The job receipt proves which remote request and builder context completed; it
is not a package acquisition receipt. After promotion, add the matching
target-specific signed HTTPS binhost to the package source catalog and run
`volatoo-acquire`. That second step independently verifies `Packages`, GPKG
hashes, signatures and Portage compatibility before layer composition.

The control-plane contract has a local deterministic test double. A real
infrastructure Gate remains pending until Portage Engine publishes stable
Volatoo OpenRC and systemd catalog targets plus target-separated signed
binhost indexes. Those targets must enforce the binding's required FEATURES
as server-owned policy; FEATURES is intentionally not accepted as arbitrary
client configuration.

## Binary-only layer staging

`compose-layer-docker.sh` is the P3U-3 entry point. It resolves the selected
published generation from the state store, independently verifies all
referenced objects while reconstructing its root into a Docker volume, then
chroots into that exact parent. It verifies the complete acquisition,
constructs a transaction-only PKGDIR and invokes Portage with
`--usepkgonly`, `--binpkg-respect-use=y` and
`--binpkg-changed-deps=y`. It snapshots the pristine root before and after
installation, captures changed paths with ownership, ACLs and xattrs, and
writes canonical tombstones.

SquashFS compression runs in a separate minimal container. The staging root
never receives `mksquashfs`, and neither container modifies the live host root.
The intermediate layer tree stays on a Docker volume so Linux ownership, ACLs
and xattrs are preserved when the host is macOS. Only the SquashFS object and
canonical metadata are exported. Finalization writes `transaction.json`,
`portage-state.json` and a generation-v2 candidate that appends exactly one
layer. It deliberately does not update a `current` pointer; atomic publication
belongs to P3U-4.

```sh
update/compose-layer-docker.sh \
  --state /.volatoo/state \
  --generation current \
  --build-context /path/build-context.json \
  --build-spec /path/build-spec.json \
  --acquisition /path/acquisition.json \
  --store /volatoo/system/objects \
  --output-dir /path/layer-output
```

Additional pinned repositories are mounted with
`--repository NAME=/absolute/path`. The pinned `--portage-image` contributes
only the Gentoo repository snapshot; it is never used as the parent root.

## Generation publication and rollback

`volatoo-generation` publishes the P3U-4 closure to the state filesystem and
manages boot selection:

On a running Volatoo host, `/.volatoo/state/volatoo/system` is intentionally
read-only. A mutating update transaction must run through the serialized
private view:

```sh
/usr/libexec/volatoo-update-view \
  /usr/local/libexec/volatoo-update-transaction
```

The transaction receives its writable state path in
`VOLATOO_UPDATE_STATE` (`/run/volatoo/update-state`). Read-only inspection can
continue to use `/.volatoo/state`. The examples below use an installer or
offline mount at `/mnt/volatoo-state`; inside the running host, substitute
`"$VOLATOO_UPDATE_STATE"` from the private transaction.

```sh
update/volatoo-generation migrate-state --state /mnt/volatoo-state

update/volatoo-generation publish \
  --state /mnt/volatoo-state \
  --generation /path/generation.json \
  --object /path/build-context.json \
  --object /path/build-spec.json \
  --object /path/source-catalog.json \
  --object /path/acquisition.json \
  --object /path/base.squashfs \
  --object /path/layer.squashfs \
  --object /path/changed-paths.json \
  --object /path/tombstones.json \
  --object /path/transaction.json

update/realize-generation-incremental-docker.sh \
  --state /mnt/volatoo-state \
  --generation sha256:... \
  --output-dir /var/tmp/volatoo-realized \
  --activate \
  --expected-current "$PARENT_GENERATION_DIGEST"

update/volatoo-generation status --state /mnt/volatoo-state
update/volatoo-generation rollback --state /mnt/volatoo-state

update/volatoo-generation pin --state /mnt/volatoo-state before-nginx
update/volatoo-generation inspect --state /mnt/volatoo-state current
update/volatoo-generation list --state /mnt/volatoo-state
update/volatoo-generation scrub --state /mnt/volatoo-state
update/volatoo-generation gc --state /mnt/volatoo-state
update/volatoo-generation gc --state /mnt/volatoo-state --delete
```

Every generation parent must already be published. Version 1 reconstructs
parents as same-context prefixes; version 2 follows the explicit
`parent_generation_digest` chain. Publication verifies the generation against
its BuildContext and PortageState, then verifies every layer's BuildSpec,
source catalog, acquisition receipt, changed paths, tombstones and transaction
before publishing the immutable manifest and derived boot plan.
The base-only parent is published first with
`--expected-current none`; later activation names the exact current digest it
was planned from. This compare-and-swap check rejects a stale concurrent
update instead of silently replacing it.

The ordinary update path publishes the manifest without selecting it, then
uses `realize-generation-incremental-docker.sh` to reconstruct the exact final
Gentoo tree in a private Linux volume. A first realization performs complete
FHS/ELF validation. An exact direct child scans only its new layer, merges
those records and tombstones into the authenticated parent index, and validates
the complete FHS, shebang, loader and ELF dependency semantics from that
merged index. It reuses
the base and layers byte for byte unless a layer's tombstones must be
translated to OverlayFS whiteouts or opaque-directory metadata. The
materializer's content-verified object snapshots remain private to that build
and are reused by later realization steps, avoiding a second read and hash of
the mutable state paths. It creates
and verifies an independent deterministic dm-verity tree for every new runtime
image. Byte-identical base and historical layer images reuse exact records
from the fully validated direct-parent v3 realization; transformed tombstone
layers are deliberately regenerated. The realizer publishes v3 with the
ordered composition, source digests, runtime images, root hashes, salts and
fixed geometry. It also publishes a content-addressed parent-tree receipt that
binds the complete FHS/ELF validation result, exact direct-parent realization,
and separate canonical validation-index and compositional tree-state objects.
The index contains the
path, symlink, shebang, loader and target-ABI ELF inputs used by the
affected-closure validator. The receipt digest is part of the signed plan,
while the larger index stays out of the boot-critical receipt path.
Receipt v3 uses the tree-state digest as the realization `tree` identity. The
small state binds the exact generation, boot plan, target, BuildContext,
validation index and direct-parent state, replacing the redundant flat scan of
every materialized file byte. Receipt v1 and v2 remain readable.
Publication and signing can therefore avoid another full hash of strictly
identical inherited v3 image records while retaining shape checks and
fail-closed dm-verity reads. Its exported `reuse-report` records cache hits and
generated trees without entering the signed plan. Set
`VOLATOO_VALIDATION_AUDIT=1` to retain the independent complete-tree scan and
require its canonical index to equal the incremental result byte for byte.
This is the periodic audit/CI Gate; ordinary exact indexed descendants use the
incremental path.

The complete closure is not recompressed for an ordinary update.
`realize-generation-docker.sh` remains the realization-v2 path for release
images and compaction. It produces and verifies one reproducible complete
SquashFS plus one deterministic dm-verity tree. Both paths bind the exact
generation, boot plan, target, BuildContext, authenticated tree identity and
`org.volatoo.gentoo-fhs/v1` contract.

With `--signing-key KEY.sec --trusted-key KEY.pub`, either realizer signs the
exact realization-plan bytes in a network-disabled container and verifies the
result before activation. Optional activation is compare-and-swap, so
`current` changes only after every image, hash tree, binding and requested
release signature is durable.
`publish --require-realization` and `select --require-realization` are
available to enforce this policy in lower-level workflows.

An automated lab or CI workflow may sign inside the network-disabled helper
container:

```sh
update/realize-generation-incremental-docker.sh \
  --state /mnt/volatoo-state \
  --generation sha256:... \
  --output-dir /var/tmp/realized \
  --signing-key /secure/volatoo-release.sec \
  --trusted-key /secure/volatoo-release.pub \
  --activate \
  --expected-current sha256:...
```

The secret key is mounted read-only into the short-lived signing container and
never enters the realized Gentoo closure or state image. Production release
keys should instead remain on an isolated signing host: publish the
realization without activation, attach the prepared state to that host, run
the lower-level `sign-realization` command below, and activate only after its
verification succeeds.

`record-incremental-realization` is the ordinary lower-level publication
interface for a trusted builder. The canonical v3 plan contains all ordered
image and dm-verity records:

```sh
update/volatoo-generation record-incremental-realization \
  --state /mnt/volatoo-state \
  --generation sha256:... \
  --plan /path/realization.plan \
  --object /path/new-or-reused-object \
  --object /path/verity-object
```

Every supplied object is hashed before publication. An object already present
in the state store may be referenced by the plan without being supplied
again; an unreferenced supplied object is rejected.

`record-realization` is the complete-closure v1/v2 publication interface:

```sh
update/volatoo-generation record-realization \
  --state /mnt/volatoo-state \
  --generation sha256:... \
  --boot-plan-digest sha256:... \
  --rootfs /path/closure.squashfs \
  --tree-digest sha256:... \
  --fhs-contract org.volatoo.gentoo-fhs/v1 \
  --verity-hash /path/closure.verity \
  --verity-root-hash 64-lowercase-hex-digits \
  --verity-salt 64-lowercase-hex-digits \
  --verity-data-blocks 12345
```

Once a realization entry exists, validation requires its exact generation,
boot plan, target, BuildContext, FHS contract, image set and builder contract.
Version 3 boots the independently authenticated base and layer stack through
dm-verity. Version 2 boots one complete persistent closure through dm-verity.
Omitting all four `--verity-*` options from `record-realization` records the
legacy version-1 contract for recovery testing; it retains eager full-object
hashing.
Corruption fails the generation or an authenticated read; it never silently
downgrades to layer replay. Unbound generation-v1 stores remain bootable for
recovery compatibility.

`sign-realization` is the separated signing interface for an offline or
operator-controlled release step. It signs the existing exact realization
object, normalizes the unauthenticated comment, verifies the result against
the supplied public key, and stores it at
`signatures/<realization-hex>/<public-key-sha256>.sig`. Repeating the command
with a new key adds a second signature for overlap during rotation:

```sh
update/volatoo-generation sign-realization \
  --state /mnt/volatoo-state \
  --generation sha256:... \
  --secret-key /secure/volatoo-release.sec \
  --trusted-key /secure/volatoo-release.pub

update/volatoo-generation select \
  --state /mnt/volatoo-state \
  --expected-current sha256:... \
  --require-realization \
  --require-signature \
  --trusted-key /secure/volatoo-release.pub \
  sha256:...
```

`org.volatoo.gentoo-fhs/v1` deliberately keeps package payloads at their normal
Gentoo paths. It rejects runtime references to `/nix/store`, the Volatoo CAS
and private staging mountpoints; the CAS remains an implementation detail.

`previous` is replaced before `current`, so an interrupted selection still
names a complete old generation. At boot, `volatoo.generation=auto` verifies
current and falls back to previous. `previous`, `none`, and an explicit
`sha256:<digest>` are available as kernel command-line recovery selections.

`scrub` hashes and validates every object reachable from `current`, `previous`
and named pins, including realization-v2/v3 SquashFS, verity and signature
files and authenticated parent-tree receipts.
`--trusted-key KEY.pub --require-signature` additionally performs the release
signature Gate for every reachable root. This is the explicit full-store
integrity pass moved out of normal boot.

`gc` is a dry run unless `--delete` is present. It retains current, previous,
named pins, their generation ancestry, boot plans and every stored
content-addressed reference reachable through their metadata. It aborts when
a retention root is invalid. After a rollback window is no longer needed,
`forget-previous --confirm sha256:...` removes only that exact pointer.

## Live service activation

Generation selection and live service activation are separate. A package
update is always durable for the next boot first. `volatoo-activate` permits an
immediate activation only when the selected generation appends one layer to
the generation running now and a canonical policy covers the complete package
and changed-path set:

```sh
update/volatoo-activate validate-policy \
  update/examples/activation-policy-openrc-nginx-v1.json

sudo update/volatoo-activate check \
  --state /.volatoo/state \
  --policy /etc/volatoo/activation.d/nginx.json

sudo update/volatoo-activate activate \
  --state /.volatoo/state \
  --policy /etc/volatoo/activation.d/nginx.json
```

The policy chooses OpenRC or systemd, a reload/restart or explicit external
handoff, configuration checks and bounded health checks. Core package and
filesystem changes always fail closed to next boot. On any failed check, the
affected live files, service action and selected generation are rolled back.
Only a healthy activation advances `/.volatoo/generation-id` and writes a
receipt.

## Base compaction

Long chains can be compacted without using the mutable live root:

```sh
update/compact-generation-docker.sh \
  --state /mnt/volatoo-state \
  --output-dir /var/tmp/volatoo-compacted \
  --minimum-layers 4 \
  --activate
```

The Docker path reconstructs the verified generation, applies tombstones and
layers in order, recompresses one base with the pinned SquashFS toolchain and
checks filesystem metadata equivalence after extraction. Publication and
selection remain separate operations internally, allowing the compaction
receipt to become durable first. Compaction emits a new BuildContext bound to
the new base digest, and selection compares the current pointer with the value
captured before reconstruction. The source generation becomes `previous` when
it was current and `--activate` is used.

## Tests

```sh
update/tests/test-volatoo-manifest.sh
update/tests/test-volatoo-plan-docker.sh
update/tests/test-volatoo-acquire-docker.sh
update/tests/test-volatoo-layer-docker.sh
update/tests/test-volatoo-generation.sh
update/tests/test-volatoo-generation-v2.sh
update/tests/test-volatoo-incremental-realization.sh
update/tests/test-volatoo-incremental-overlay-docker.sh
update/tests/test-volatoo-incremental-verity-reuse-docker.sh
update/tests/test-volatoo-signatures-docker.sh
update/tests/test-volatoo-activate.sh
update/tests/test-volatoo-compaction-docker.sh
```

The planner Docker test publishes real OpenRC and systemd base generations,
reconstructs each selected parent with a pinned repository snapshot, resolves
`app-misc/jq`, verifies each two-package closure, and confirms that a context
outside the selected parent is rejected.
The layer Docker test builds a local GPKG, installs it through the acquired
binary-only closure inside both reconstructed parents, proves byte-identical
SquashFS recompression, publishes and rematerializes each candidate, and
verifies the payload plus Portage VDB.
The generation, incremental-realization and signature tests cover publication
ordering, realization-v1/v2/v3 parsing, exact source/image ordering,
unreferenced-object rejection, explicit scrub, verity-object corruption,
missing signatures, wrong keys, key rotation, signatures over different messages,
signature GC, explicit rollback, an interrupted pointer update,
corrupt-current fallback, complete provenance and parent validation,
BuildContext/base mismatch, and stale compare-and-swap rejection.
The incremental OverlayFS Docker test round-trips whiteout character devices
and opaque-directory xattrs through the pinned SquashFS toolchain, then proves
pure deletion and replacement-directory behavior in a real lower stack.
The incremental dm-verity reuse test proves the materializer retains its
verified object snapshots, an exact direct-parent record skips hash-tree
generation, a cache miss generates a new tree, and a changed cached hash object
fails closed. The host contract test also proves that a receipt-bound direct
parent can publish inherited image records and rejects a changed parent
realization pointer.
The activation test covers eligibility, a healthy external handoff and
file/selection rollback after a failed health check. The compaction Docker
test reduces a real two-layer SquashFS generation to one verified base,
publishes and verifies its deterministic dm-verity tree, then confirms the old
chain becomes collectible only after its rollback pointer is explicitly
removed. It also proves that corrupt layer objects and boot-plan pointer swaps
fail closed before materialization. With built images and a development
kernel, the full firmware and init-system matrix is:

```sh
update/tests/test-volatoo-generation-qemu.sh \
  /path/to/kernel \
  /path/to/initramfs \
  /path/to/openrc.squashfs \
  /path/to/systemd.squashfs
```

By default this runs normal, corrupt-current and interrupted-selection
lifecycle boots for OpenRC and systemd under BIOS and UEFI with the persistent
`store-overlay` root. It then reuses a normal fixture to verify the layer
payload and tombstones in store-backed overlay, RAM-backed overlay, and
full-copy roots.
With `VOLATOO_GENERATION_QEMU_REALIZED=yes`, it additionally requires an
active realization-v2 root or realization-v3 authenticated layer stack under
BIOS and UEFI. Corrupt SquashFS data and used hash-tree blocks must fail at the
authenticated SquashFS mount.
Supplying `VOLATOO_GENERATION_QEMU_SIGNING_KEY` and
`VOLATOO_GENERATION_QEMU_TRUSTED_KEY` signs that fixture and requires the
public key to be embedded in the supplied initramfs. The signed lane verifies
BIOS/UEFI boot, corrupts a current-only dm-verity image and requires automatic
rollback to the independently signed parent under both firmware paths. It also
corrupts data, hash-tree, parent-tree receipt and detached-signature objects in
explicit-selection images; each must fail closed at its expected trust gate.
The full-copy lane has a separate 900-second timeout because cross-architecture
TCG must expand the complete Gentoo root. A quicker smoke run can select one
firmware and keep only the RAM-backed lane:

```sh
VOLATOO_GENERATION_QEMU_FIRMWARES=bios \
VOLATOO_GENERATION_QEMU_PAYLOAD_ROOT_MODES=ram-overlay \
update/tests/test-volatoo-generation-qemu.sh \
  /path/to/kernel \
  /path/to/initramfs \
  /path/to/openrc.squashfs \
  /path/to/systemd.squashfs
```

The acquisition Docker test creates real GPKGs with `quickpkg` for both init
targets. It exercises local acquisition, USE and hash rejection, explicit
missing-package actions, mandatory Volatoo provenance, temporary GPG signing
and a TLS-protected remote binhost. No generated package or key is retained.

The layer Docker test creates a tiny no-network ebuild in a temporary overlay,
builds and acquires its GPKG, installs it binary-only in fresh OpenRC and
systemd containers, and verifies the resulting SquashFS transaction and
generation candidate.

The checked-in examples use placeholder revisions and digests. They describe
the contract, not published Volatoo artifacts.
