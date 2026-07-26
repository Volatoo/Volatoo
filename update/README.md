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
system layers. The generation manifest digest is the generation identity.

`org.volatoo.portage-engine-target/v1` is an operator-reviewed binding from a
Volatoo hard target to a Portage Engine profile, repository set, immutable
builder image, mirror snapshot and target-separated binhost path.
`org.volatoo.portage-engine-job/v1` records the request and resolved builder
provenance returned by one successful remote build.

The JSON schemas document the wire format:

- `schemas/build-context-v1.schema.json`
- `schemas/build-spec-v1.schema.json`
- `schemas/generation-v1.schema.json`
- `schemas/layer-paths-v1.schema.json`
- `schemas/layer-transaction-v1.schema.json`
- `schemas/package-acquisition-v1.schema.json`
- `schemas/package-source-catalog-v1.schema.json`
- `schemas/package-source-query-v1.schema.json`
- `schemas/portage-engine-job-v1.schema.json`
- `schemas/portage-engine-target-v1.schema.json`
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
digest agree. It does not inspect the referenced SquashFS or tombstone objects;
the layer composer and boot verifier will add object verification in later
milestones.

## Local Portage planner

`volatoo-plan` must run inside a pristine root reconstructed from the selected
generation. It deliberately does not resolve against the mutable live tmpfs
root. The root must contain Portage's Python modules and installed VDB, while
every configured repository must be mounted at the revision named by the
build context.

Repository revisions are read from `metadata/timestamp.commit`, a
`.volatoo-revision` snapshot marker, or a clean Git checkout. The planner
rejects a missing marker, a dirty Git tree, an extra repository or a revision
mismatch. It also rejects mismatched Portage, ARCH, CHOST, libc, ABI, profile
revision and init system. Init detection uses both the profile chain and the
installed OpenRC/systemd package, so changing only a target ID cannot bypass
the check.

Example inside the selected root:

```sh
update/volatoo-plan \
  --build-context /run/volatoo/build-context.json \
  --output /var/tmp/build-spec.json \
  --query-output /var/tmp/package-source-query.json \
  app-misc/jq
```

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

`compose-layer-docker.sh` is the P3U-3 entry point. It runs the selected Gentoo
root in a disposable Docker container, verifies the complete acquisition,
constructs a transaction-only PKGDIR and invokes Portage with
`--usepkgonly`, `--binpkg-respect-use=y` and
`--binpkg-changed-deps=y`. It snapshots the pristine root before and after
installation, captures changed paths with ownership, ACLs and xattrs, and
writes canonical tombstones.

SquashFS compression runs in a separate minimal container. The staging root
never receives `mksquashfs`, and neither container modifies the live host root.
The intermediate layer tree stays on a Docker volume so Linux ownership, ACLs
and xattrs are preserved when the host is macOS. Only the SquashFS object and
canonical metadata are exported. Finalization writes `transaction.json` and a
generation candidate that appends exactly one layer. It deliberately does not
update a `current` pointer; atomic publication belongs to P3U-4.

```sh
update/compose-layer-docker.sh \
  --stage-image gentoo/stage3@sha256:... \
  --build-context /path/build-context.json \
  --build-spec /path/build-spec.json \
  --acquisition /path/acquisition.json \
  --parent-generation /path/generation.json \
  --store /volatoo/system/objects \
  --output-dir /path/layer-output
```

Additional pinned repositories are mounted with
`--repository NAME=/absolute/path`. The selected Docker root must represent
the parent generation and carry the exact Portage/profile baseline named by
the build context.

## Generation publication and rollback

`volatoo-generation` publishes the P3U-4 closure to the state filesystem and
manages boot selection:

```sh
update/volatoo-generation migrate-state --state /mnt/volatoo-state

update/volatoo-generation publish \
  --state /mnt/volatoo-state \
  --generation /path/generation.json \
  --object /path/build-context.json \
  --object /path/base.squashfs \
  --object /path/layer.squashfs \
  --object /path/tombstones.json \
  --object /path/transaction.json \
  --activate

update/volatoo-generation status --state /mnt/volatoo-state
update/volatoo-generation rollback --state /mnt/volatoo-state

update/volatoo-generation pin --state /mnt/volatoo-state before-nginx
update/volatoo-generation inspect --state /mnt/volatoo-state current
update/volatoo-generation list --state /mnt/volatoo-state
update/volatoo-generation gc --state /mnt/volatoo-state
update/volatoo-generation gc --state /mnt/volatoo-state --delete
```

Every referenced object is verified before the immutable manifest and derived
boot plan are published. `previous` is replaced before `current`, so an
interrupted selection still names a complete old generation. At boot,
`volatoo.generation=auto` verifies current and falls back to previous.
`previous`, `none`, and an explicit `sha256:<digest>` are available as kernel
command-line recovery selections.

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
receipt to become durable first. The source generation becomes `previous`
when `--activate` is used.

## Tests

```sh
update/tests/test-volatoo-manifest.sh
update/tests/test-volatoo-plan-docker.sh
update/tests/test-volatoo-acquire-docker.sh
update/tests/test-volatoo-layer-docker.sh
update/tests/test-volatoo-generation.sh
update/tests/test-volatoo-activate.sh
update/tests/test-volatoo-compaction-docker.sh
```

The planner Docker test resolves `app-misc/jq` with pinned OpenRC and systemd
Gentoo stage3 images plus a pinned repository image, verifies each two-package
closure, and confirms that an OpenRC root rejects a systemd context.
The layer Docker test builds a local GPKG, installs it through the acquired
binary-only closure in both init variants, proves byte-identical SquashFS
recompression, reconstructs each candidate on a fresh stage3 root and verifies
the payload plus Portage VDB.
The generation test covers publication ordering, explicit rollback, an
interrupted pointer update, corrupt-current fallback and incomplete-closure
rejection. The activation test covers eligibility, a healthy external handoff
and file/selection rollback after a failed health check. The compaction Docker
test reduces a real two-layer SquashFS generation to one verified base, then
confirms the old chain becomes collectible only after its rollback pointer is
explicitly removed. With built images and a development kernel, the full firmware and
init-system matrix is:

```sh
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
