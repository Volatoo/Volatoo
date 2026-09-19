# OpenRC / systemd persistence and shutdown parity

Status: Phase 3 parity assessment. This note records, with file and line
references, exactly what persistence and shutdown integration each init system
has, where the two are equivalent, and where they intentionally differ.

The persistence engine itself is init-agnostic. `volatoo-persist`,
`volatoo-identity`, and the `volatoo-persist-early` handoff wrapper run the
same code for both targets; only the *shutdown hook* that runs the final
`sync` differs in shape, because OpenRC and systemd express "run this when the
system stops" differently. The table below maps each concern to its source.

## The early handoff (shared, init-agnostic)

Both roots receive the same three tools and the same first-boot access helper,
installed unconditionally by `scripts/build-catalyst-squashfs.sh`:

| Path in image | Source | Install |
|---|---|---|
| `/usr/sbin/volatoo-persist` | `persist/volatoo-persist` | `scripts/build-catalyst-squashfs.sh:245` |
| `/usr/sbin/volatoo-identity` | `persist/volatoo-identity` | `scripts/build-catalyst-squashfs.sh:247` |
| `/usr/libexec/volatoo-persist-early` | `persist/volatoo-persist-early` | `scripts/build-catalyst-squashfs.sh:249` |
| `/usr/libexec/volatoo-firstboot-access` | `image/catalyst/overlay/usr/libexec/volatoo-firstboot-access` | `scripts/build-catalyst-squashfs.sh:244` |

The initramfs performs the same handoff for both targets: when state is
mounted it executes `switch_root /newroot /usr/libexec/volatoo-persist-early
"$target_init"` (`initramfs/init:2856-2858`). That wrapper, in a fixed order,
restores sync generations, applies machine identity, and applies administrator
access before `exec`ing the real init (`persist/volatoo-persist-early:6-37`).
Because the wrapper is chosen by the initramfs and is identical for both init
systems, `/etc` three-way merge, machine-identity restore, and log binding are
already equivalent by construction.

### `/etc` three-way merge

`volatoo-persist restore` captures the new image's pristine `/etc`, reads the
last synchronized generation and the previous pristine base, and merges them
(`persist/volatoo-persist:499-519`, merge engine `persist/volatoo-persist:395-496`).
The `/etc` specialization lives at `persist/volatoo-persist:513-516`. It is
called from the early wrapper (`persist/volatoo-persist-early:9`) and has no
init-system branch.

### Machine identity restore

`volatoo-identity apply` creates or restores `/etc/machine-id`, SSH host keys,
and the `/var/log` bind (`persist/volatoo-identity:327-341`, subroutines
`149-324`). Called from `persist/volatoo-persist-early:25`; no init-system
branch.

### Log persistence

The default log bind mounts `identity/logs` over `/var/log`
(`persist/volatoo-identity:296-324`). This is the same mechanism for both
targets. One nuance: OpenRC runs sysklogd (`image/catalyst/package-sets/minimal-openrc:2`),
which writes to `/var/log`; systemd runs journald. journald persists to
`/var/log/journal` when that directory exists (`Storage=auto`), otherwise to
the volatile `/run/log/journal`. The image does not create `/var/log/journal`
explicitly, so whether journald's *own* records land in the bind-mounted
`/var/log` depends on the systemd stage3 shipping that directory (Gentoo's
`sys-apps/systemd` `keepdir`s it). This is an inference from systemd defaults,
not a boot observation; the identity bind itself is init-agnostic and is what
the QEMU identity Gate verifies.

## The shutdown sync hook (one per init system)

| Concern | OpenRC | systemd |
|---|---|---|
| Unit file | `persist/volatoo-persist.initd` | `persist/volatoo-persist.service` |
| Installed as | `/etc/init.d/volatoo-persist` (`scripts/build-catalyst-squashfs.sh:313-315`) | `/usr/lib/systemd/system/volatoo-persist.service` (`scripts/build-catalyst-squashfs.sh:318-321`) |
| Enabled via | `stage4/rcadd ... volatoo-persist|default` (`scripts/build-catalyst-squashfs.sh:338`) | `multi-user.target.wants` symlink (`image/catalyst/finalize.sh:42-47`) |
| Guard: state present | `persist/volatoo-persist.initd:14` | `persist/volatoo-persist.service:5` |
| Guard: sync configured | `persist/volatoo-persist.initd:18` | `persist/volatoo-persist.service:6` |
| Sync command | `/usr/sbin/volatoo-persist sync` (`persist/volatoo-persist.initd:38`) | `ExecStop=/usr/sbin/volatoo-persist sync` (`persist/volatoo-persist.service:11`) |
| Ordering | `need localmount` (`persist/volatoo-persist.initd:9`) | `After=local-fs.target` + `Before=umount.target` (`persist/volatoo-persist.service:3-4`) |

Both units run the *same* `volatoo-persist sync` command on stop, guarded by
the same two conditions (`layout-version` marker and `image-id`). The OpenRC
service relies on runlevel-stop ordering (stops before `localmount` because it
`need`s it); the systemd unit uses `Before=umount.target` with
`RemainAfterExit=yes` so `ExecStop` runs during shutdown. `TimeoutStopSec=5min`
(`persist/volatoo-persist.service:13`) bounds a wedged sync; OpenRC uses its
own service stop timeout.

## The divergences that matter

1. **Shutdown-sync test coverage is OpenRC-only.** The only automated
   sync-on-shutdown exercise is the `VOLATOO_TEST_SHUTDOWN_SYNC=yes` path in
   `scripts/test-qemu-boot.sh`, which is bound to the OpenRC auto-login
   console (`scripts/test-qemu-boot.sh:136-139,467-470,681-699`) and reports
   "OpenRC shutdown did not synchronize /etc" (`scripts/test-qemu-boot.sh:807`).
   The systemd `ExecStop` path is not exercised by any gate, and no contract
   test asserts that the two units stay equivalent.
2. **The parity is not itself under test.** Nothing fails if, for example, the
   systemd unit drops its `Before=umount.target` ordering or the OpenRC
   service stops calling `volatoo-persist sync`. `scripts/tests/test-init-parity.sh`
   closes this gap by rendering both overlays and comparing the shared tools
   and the two units.

## Enforcement

`scripts/tests/test-init-parity.sh` renders both Catalyst overlays with the
same fake-Docker technique as `scripts/tests/test-image-init-selection.sh` and
asserts: the shared persistence tools are byte-identical across targets; the
OpenRC target installs exactly `/etc/init.d/volatoo-persist` and the systemd
target exactly `/usr/lib/systemd/system/volatoo-persist.service`; and both
units invoke `volatoo-persist sync` guarded by the same two conditions. It runs
on every pull request via `weekly-minimal-image.yml` and fails if the two
targets diverge.
