# Default machine identity and logs

Status: Phase 2 implementation.

## Decision

A Volatoo boot without state remains completely volatile. When a valid
`VOLATOO-STATE` filesystem is present, three machine-specific resources persist
by default:

- `/etc/machine-id`;
- OpenSSH host keys below `/etc/ssh`;
- `/var/log`.

These defaults do not require `persist.conf`. They prevent an installed
machine from presenting a new identity on every boot and keep operational
history available after the volatile root is discarded.

## First boot and restore

The initramfs moves state into the new root, then starts
`volatoo-persist-early` instead of the real init. The wrapper first restores
any configured sync generations and then runs `volatoo-identity apply`.
Identity therefore wins if a broad `/etc` snapshot contains different copies
of the same files.

On the first boot with state:

1. A UUID is read from `/proc/sys/kernel/random/uuid`, normalized to the
   32-lowercase-hexadecimal machine-id format, written atomically to state, and
   installed as `/etc/machine-id`.
2. Any host keys accidentally present in the system image are removed.
   `ssh-keygen -A` creates a machine-specific RSA, ECDSA, and ED25519 key set.
   The complete set is atomically published to state before boot continues.
3. The image's initial `/var/log` is copied to state once and that state
   directory is bind-mounted over `/var/log`.

Later boots restore the stored machine-id and host keys and bind the same log
directory. Identity is written to state immediately, and log writes go
directly to state, so neither depends on a clean shutdown.

## Opt-out configuration

The optional state file `/volatoo/config/identity.conf` is data, not shell
code. Each non-comment line contains a setting and `yes` or `no`:

```text
machine-id      yes
ssh-host-keys   yes
logs            yes
```

All settings default to `yes` when the file or an individual line is absent.
Names may appear only once; unknown names, extra fields, symbolic links, and
values other than `yes` or `no` stop the early handoff rather than silently
changing identity behavior.

Disabling a setting stops restoring or creating that resource. Existing state
is deliberately retained for recovery if the setting is enabled again.
This opt-out controls only the implicit identity layer: an explicit broad
policy such as `sync /etc etc` may still persist machine-id and SSH keys, and
an explicit `/var/log` policy remains active even when the default `logs`
setting is `no`.

An explicit persistence policy that targets `/var/log`, one of its children,
or an ancestor such as `/var` takes precedence over the default log bind. This
allows logs to use `sync`, `overlay`, or a differently keyed `bind` policy
without two persistence mechanisms shadowing one another.

## State and safety

Identity data lives below `/volatoo/data/identity`:

```text
identity/
├── machine-id
├── ssh-host-keys/
│   ├── ssh_host_*_key
│   ├── ssh_host_*_key.pub
│   └── complete
├── logs/
└── logs-initialized
```

The identity root and SSH state directory are mode `0700`; private key modes
from `ssh-keygen` are preserved. State directories, files, completion markers,
and the lock file are rejected when they are symbolic links or unexpected file
types. Temporary SSH key sets are renamed into place only after every key has
been copied and the completion marker is durable.

Machine-id is not a secret. SSH private host keys and logs can be sensitive.
Until encrypted state is implemented, both are plaintext on the state
filesystem and must be protected by physical and filesystem access controls.
