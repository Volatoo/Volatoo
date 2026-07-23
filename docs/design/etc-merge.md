# `/etc` persistence across image updates

Status: Phase 2 decision — use a three-way merge.

## Decision

Volatoo will merge the last synchronized `/etc` with the new image's pristine
`/etc`, using the previous image's pristine `/etc` as the common base. It will
not blindly restore an old snapshot over every new image.

The three inputs are:

```text
base   pristine /etc from the image on which local was last synchronized
local  last synchronized /etc from the running machine
new    pristine /etc from the image being booted
```

This is a path-aware tree merge, not a text-only merge of the entire
directory.

## Why not snapshot restore

Restoring an old tree is simple and deterministic while the image is unchanged.
Across an image update, however, it overwrites new package defaults, resurrects
files intentionally removed by the image, and can leave configuration that no
longer matches the installed binaries. Copying the snapshot without deleting
new files avoids some loss but no longer represents an exact snapshot and
still cannot distinguish an administrator edit from an obsolete default.

Volatoo images are immutable and identified by SHA-256, so the pristine old and
new trees are knowable. That makes a real three-way merge practical and gives
better upgrade semantics than treating every old file as an intentional local
override.

## Merge rules

For each path, compare `local` and `new` with `base`:

| Local change | Image change | Result |
|---|---|---|
| unchanged | unchanged | keep `new` |
| unchanged | changed | take `new` |
| changed | unchanged | take `local` |
| changed | changed identically | take either identical result |
| changed | changed differently | keep `local`, stage `new`, record conflict |

Creation, deletion, file type, symlink target, ownership, mode, and content are
all part of the comparison. A local deletion is preserved when the image entry
is unchanged. A delete/modify or incompatible type change is a conflict.

On conflict, the live path keeps the administrator's local version. The new
image version is staged beside it using Gentoo's `._cfgNNNN_<name>` convention
when that representation is safe. This lets the existing `etc-update` or
`dispatch-conf` workflow resolve ordinary file conflicts. Structural conflicts
that cannot be represented beside the path are stored in the state snapshot
area and listed in a conflict manifest. Boot continues with a prominent
warning; it never inserts conflict markers into a live configuration file.

## State model

An `/etc` sync policy with key `etc` uses:

```text
/volatoo/data/sync/etc/
├── current                       # name of the selected complete generation
├── bases/
│   └── <image-sha256>/
│       ├── tree/                 # immutable pristine /etc from that image
│       └── complete
└── generations/
    └── <UTC-timestamp>-<uuid>/
        ├── tree/                 # synchronized machine /etc
        ├── image-id              # image on which this tree was synchronized
        └── complete
```

The initramfs requires a verified image SHA-256 before applying the `/etc`
merge. It captures each new pristine tree under its digest before modifying
the tmpfs copy. `volatoo-persist sync` writes a new immutable generation and
atomically replaces `current` only after the snapshot is complete.
Content-addressed pristine bases may be garbage-collected only when no local
generation refers to them.

Conflict manifests and any non-inlineable entries live below:

```text
/volatoo/snapshots/etc-conflicts/<UTC-timestamp>-<uuid>/
```

## Same-image boots and first boot

On the first boot with no local snapshot, the image's `/etc` is used unchanged.
The first successful sync records the image tree as the pristine base and the
then-current running tree as the local snapshot.

When the current image digest matches the generation's `image-id`, the
three-way rules reduce to an exact local restore, including tracked deletions.

## Failure policy

Missing bases, malformed metadata, unsafe paths, or an incomplete transactional
snapshot are persistence errors and must not be guessed around. The early
restore opens an emergency shell instead of starting the real init with
partially restored state.

Ordinary merge conflicts are different: they preserve the local version, stage
the image version, record a manifest, and allow boot. This follows Gentoo's
existing configuration-protection expectations while making unresolved
updates visible. `restore` exits with status `2` for this non-fatal condition;
the early boot wrapper logs it and continues.

## Consequences

Three-way merging costs more implementation work and state space than snapshot
restore. In exchange, Volatoo can update its immutable image without silently
discarding either administrator changes or new package configuration. The
merge engine must be tested against regular files, directories, symlinks,
deletions, metadata changes, binary files, and power loss during sync.

Encryption is outside this decision. Until encrypted state is implemented,
persisting `/etc` also means secrets stored there are present on the state
filesystem in plaintext.
