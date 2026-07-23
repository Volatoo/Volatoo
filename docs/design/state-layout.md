# State filesystem layout

Status: Phase 2 layout version 1.

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
`/.volatoo/state`. A discovered filesystem with a missing or unsupported
layout marker is a boot error; silently using an unknown layout could corrupt
persistent data.

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
└── snapshots/            # versioned recovery snapshots
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
