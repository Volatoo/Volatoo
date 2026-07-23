# Persistence policy

Status: Phase 2 declarative policy version 1.

## Configuration

The state filesystem may contain `/volatoo/config/persist.conf`. It is a data
file, never a shell script, and the initramfs does not source or evaluate it.
Blank lines and lines whose first field begins with `#` are ignored. Every
policy line has exactly three whitespace-separated fields:

```text
policy  absolute-target  storage-key
```

For example:

```text
bind     /home      home
overlay  /var/lib   var-lib
sync     /var/log   var-log
```

Targets must be existing, real directories in the image. They must be absolute
and normalized, may not overlap another configured target, and may not select
`/`, `/dev`, `/proc`, `/run`, `/sys`, or `/.volatoo`. A storage key contains
only ASCII letters, digits, `.`, `_`, and `-`, and is unique within its policy
type. The configuration is limited to 64 entries and 512 characters per line.

The complete file is validated before any policy creates backing data or
mounts a filesystem. Invalid configuration is a boot failure with a stable
`persist.*` diagnostic code.

## Policy behavior

### `bind`

The first successful boot copies the image directory into
`/volatoo/data/bind/<key>/root` and writes an initialization marker beside it.
That backing directory is then bind-mounted over the target. Every subsequent
write goes directly to the state filesystem and is visible on the next boot.
The initial copy preserves the target directory's ownership and mode.

### `overlay`

The image directory remains the lower layer. Persistent upper and work
directories live below `/volatoo/data/overlay/<key>/`, and the merged OverlayFS
is mounted at the target. Image updates therefore supply a new lower layer
while locally created and modified entries remain in the upper layer. Standard
OverlayFS whiteouts preserve deletions.

### `sync`

The entry declares a path that is snapshotted below
`/volatoo/data/sync/<key>/`. Early in every boot, before the real init starts,
`volatoo-persist restore` captures the current image's pristine target and
restores the latest complete generation. `volatoo-persist sync` creates a new
immutable generation from the live target and atomically advances its `current`
pointer.

Trees are copied with ownership, modes, hard links, ACLs, extended attributes,
and deletions preserved. Content checksums are enabled so equal-size files
changed within the same filesystem timestamp interval are not skipped.

The public commands are:

```sh
volatoo-persist status
volatoo-persist sync
```

`status` prints the target, storage key, and current generation (or `never`).
`sync` may be run at any time after boot. The OpenRC service also runs it while
leaving the default runlevel, before `localmount` unmounts the state
filesystem. An interrupted sync leaves the previous `current` generation
selected.

`/etc` uses a specialized three-way merge rather than a blind tree restore.
The previous pristine image tree, last synchronized local tree, and new
pristine image tree are compared path by path. See
[`etc-merge.md`](etc-merge.md) for the decision and conflict rules.

Every sync policy requires a configured and successfully verified image
SHA-256. The digest identifies pristine bases across image upgrades; boot stops
with `persist.image-id` rather than applying a snapshot against an unknown
image.

## Safety and lifecycle

Declarative path policies are opt-in. Without a state filesystem the root
remains fully volatile. A present state filesystem enables the separate
machine identity and log defaults unless
`/volatoo/config/identity.conf` disables them. See
[`machine-identity.md`](machine-identity.md).

Removing a policy line stops applying that policy but deliberately leaves its
backing data intact for manual recovery.

State-controlled paths are checked for symbolic links and unexpected file
types before use. Bind and overlay targets are also rejected when they are
symbolic links, preventing a policy from escaping its declared location.
Nested and duplicate targets are forbidden because mount ordering would
otherwise change their meaning.
