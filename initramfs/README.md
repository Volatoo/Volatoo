# Volatoo initramfs

The standalone generator builds the early userspace that locates a Gentoo
SquashFS image, mounts the selected immutable system as a read-only lower,
creates a disposable tmpfs upper, and uses `switch_root` to start the stage3
userspace. Full-copy and RAM-backed roots remain available for compatibility
and removable-media use cases.

## Inputs

- Docker with Buildx for producing the stage3 squashfs;
- an x86_64 kernel built with the validated
  [`kernel/config/amd64.fragment`](../kernel/config/amd64.fragment) baseline;
- a statically linked x86_64 BusyBox binary containing the applets used by
  `init`;
- `qemu-system-x86_64`, `cpio`, and `gzip` on the host.

The standalone initramfs contains no kernel module tree, so the baseline keeps
all early-boot storage and filesystem support built in. The kernel and BusyBox
remain explicit inputs because they are build artifacts and must not be
committed.

## Build the stage3 image

The default build uses the official `gentoo/stage3:latest` image for
`linux/amd64`. `mksquashfs` runs in a native Alpine build stage, so compression
does not require x86 emulation on an Apple Silicon host.

The OCI source sets `rc_sys="docker"`; the conversion removes that setting so
OpenRC starts its normal machine services rather than its container subset.

```sh
scripts/build-stage3-squashfs.sh
```

The results are `out/volatoo-stage3.squashfs` and its
`out/volatoo-stage3.squashfs.sha256` checksum. To pin the source image or
select a different Zstd level:

```sh
VOLATOO_GENTOO_IMAGE='gentoo/stage3@sha256:...' \
VOLATOO_ZSTD_LEVEL=10 \
scripts/build-stage3-squashfs.sh
```

Levels 1 through 22 are accepted. Level 19 is the prototype default. It reduced
the stock stage3 image by about 47 MiB compared with level 15 in the Phase 0
matrix, without a measurable single-core extraction penalty.

## Build the initramfs and boot

From the repository root:

```sh
scripts/prepare-verity-root-docker.sh out/verity-root
scripts/prepare-signify-root-docker.sh out/signify-root
scripts/build-initramfs.sh \
  --busybox /path/to/busybox \
  --verity-root out/verity-root \
  --signify-root out/signify-root \
  --trust-key /secure/volatoo-release.pub
scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

The generator embeds `initramfs/default.conf`. Supply a different trusted
configuration at build time with `--config`:

```sh
scripts/build-initramfs.sh \
  --busybox /path/to/busybox \
  --verity-root out/verity-root \
  --signify-root out/signify-root \
  --trust-key /secure/volatoo-release.pub \
  --config /path/to/initramfs.conf \
  --output out/custom-initramfs.cpio.gz
```

`prepare-verity-root-docker.sh` exports only the pinned amd64 `veritysetup`
runtime closure. It adds about 2.8 MiB compressed to the current BusyBox
initramfs and is required for realization-v2 and realization-v3 boots.
Omitting `--verity-root` keeps direct-image and realization-v1 recovery
support, but a v2/v3 generation fails closed with
`generation.verity-helper`.

`prepare-signify-root-docker.sh` exports the pinned amd64 OpenBSD `signify`
verifier and its minimal dynamic runtime. The test build increased the
compressed initramfs from about 3.4 MiB to 3.5 MiB. `--trust-key` may be
repeated during key rotation; keys are installed under their exact SHA-256
digest. No secret key enters the initramfs. With the default `required` policy,
omitting the verifier or every matching public key makes a stored generation
fail closed. Direct-image boot remains available when no generation is
selected.

The supported settings are:

| Setting | Default | Purpose |
|---|---|---|
| `VOLATOO_IMAGE` | `/dev/vda` | `/dev/...`, `LABEL=...`, or `UUID=...` |
| `VOLATOO_IMAGE_FILE` | empty | SquashFS path inside a filesystem or ISO |
| `VOLATOO_IMAGE_SHA256` | empty | Expected lowercase SHA-256 digest |
| `VOLATOO_INIT` | `/sbin/init` | Program executed after `switch_root` |
| `VOLATOO_ROOT_MODE` | `store-overlay` | `store-overlay`, `ram-overlay`, `copy`, or legacy `overlay` |
| `VOLATOO_TMPFS_SIZE` | `80%` | Percentage of RAM allowed for the tmpfs |
| `VOLATOO_STATE` | `LABEL=VOLATOO-STATE` | State device spec, or `none` |
| `VOLATOO_STATE_REQUIRED` | `no` | Whether missing state is a boot failure |
| `VOLATOO_GENERATION` | `auto` | `auto`, `previous`, `none`, or a digest |
| `VOLATOO_SIGNATURE_POLICY` | `required` | `required` or explicit recovery mode `allow-unsigned` |

Kernel parameters `volatoo.image=`, `volatoo.image-file=`,
`volatoo.image-sha256=`, `volatoo.init=`, `volatoo.root=`, and
`volatoo.tmpfs-size=`, `volatoo.state=`, `volatoo.state-required=`, and
`volatoo.generation=`, and `volatoo.signature-policy=` override the embedded
settings for one boot.

A raw SquashFS partition needs only `VOLATOO_IMAGE`. For a SquashFS stored
inside a labeled filesystem or ISO:

```sh
VOLATOO_IMAGE='LABEL=VOLATOO-BOOT'
VOLATOO_IMAGE_FILE=/volatoo/root.squashfs
```

The initramfs waits up to ten seconds for the matching block device, so the same
configuration works for built-in storage and USB media. Filesystem and ISO
containers are mounted read-only, and the SquashFS file is attached through a
read-only loop device.

The discovery path is validated in QEMU with both a labeled ISO exposed as USB
mass storage and a UUID-selected ext4 image exposed as virtio block. Both
layouts located `/volatoo/root.squashfs` and entered the Gentoo userspace.

## Persistent state discovery

Phase 2 state lives on a filesystem labeled `VOLATOO-STATE`. Discovery is
optional by default: when no matching filesystem is present, Volatoo logs that
it is continuing without persistence and does not delay the volatile boot.
Set `VOLATOO_STATE_REQUIRED=yes` to wait up to ten seconds and enter the rescue
environment with `state.not-found` if the filesystem remains absent.
`VOLATOO_STATE=none` disables discovery explicitly.

A discovered state filesystem is mounted read-write and must contain
`/volatoo/layout-version` with the supported value `1`. An optional
`/volatoo/system/layout-version` value of `1` enables immutable generation
selection without changing the Phase 2 persistence layout version. Before
`switch_root`, the mount is moved to `/.volatoo/state`, where later persistence
policies can use it without depending on a kernel device name. Missing or
unsupported layout metadata is a fatal error rather than an invitation to
modify unknown data.
When the system-generation sublayout exists, the initramfs bind-mounts
`/.volatoo/state/volatoo/system` read-only. Persistence and identity paths on
the same filesystem remain writable. Updates obtain a temporary writable view
only inside the private namespace created by
`/usr/libexec/volatoo-update-view`.
The complete versioned layout is documented in
[`docs/design/state-layout.md`](../docs/design/state-layout.md).

Create an empty 128 MiB test filesystem using Docker:

```sh
scripts/build-state-image.sh
```

The generated image includes an empty system-generation sublayout. A prepared
state tree containing published generations can be converted to ext4 with:

```sh
VOLATOO_STATE_SIZE=1G scripts/build-state-image.sh \
  --source /path/to/prepared-state-root \
  out/volatoo-generation-state.ext4
```

With `VOLATOO_GENERATION=auto`, a safe `current` pointer selects the default
generation. The initramfs verifies the canonical manifest digest, derived boot
plan and BuildContext. Before parsing a realization, release mode verifies an
OpenBSD `signify` Ed25519 signature over its exact content-addressed bytes.
Realization v2 binds the complete SquashFS plus a dm-verity hash-tree object,
root hash, salt and geometry. Realization v3 binds an ordered base and FHS
update-layer stack with independent dm-verity records and explicit OverlayFS
whiteout composition. New v3 plans also bind a small content-addressed
parent-tree receipt and, through it, an off-boot-path FHS/ELF validation index;
receipt v3 also binds the host-validated compositional tree state. Early
userspace verifies the receipt object before accepting the image stack; host
inspection and scrub follow and verify the larger index and tree-state objects.
Boot checks all objects
are safe regular files of their
declared sizes, opens `/dev/mapper/volatoo-root` for v2 or
`/dev/mapper/volatoo-lower-N` for v3, and lets the kernel authenticate blocks
lazily. It exposes the contract version, `dm-verity` or
`dm-verity-layer-stack`, `signify-ed25519`, the signing-key digest and
authenticated image identity below `/.volatoo/`. Realization v1 remains
compatible when signed and verifies the complete SquashFS SHA-256 eagerly. A
rejected current generation falls back to a fully verified and independently
signed `previous`.
`VOLATOO_GENERATION=previous`, `none`, or an explicit digest provides
deterministic recovery behavior.

`VOLATOO_SIGNATURE_POLICY=allow-unsigned` permits old realizations and legacy
layer plans with a prominent warning. It is a deliberate security downgrade,
not a best-effort mode: state modification can remove a signature when this
policy is active. The default `required` policy never performs that downgrade.

`store-overlay` keeps the verified immutable closure or authenticated
base/layer stack on persistent storage as a read-only lower and puts only the
writable OverlayFS upper/work directories in tmpfs. This is the default
because it reads compressed blocks on demand instead of expanding the complete
root at boot. For copy roots, the verified merged tree is copied into the root
tmpfs. `ram-overlay` currently supports one realized image, copies that
compressed image into a dedicated tmpfs, re-verifies the RAM snapshot,
remounts it read-only, and uses a separate tmpfs
for the overlay upper and work directories. The source container is unmounted
before handoff, so the lower no longer references its image storage. The
old `overlay` spelling is retained as a compatibility alias for the
store-backed topology. A realization-v2 generation uses its complete closure
as the read-only lower. A realization-v3 generation composes independently
authenticated images as the read-only lower stack; deletion and
remove-then-replace behavior is encoded in that stack. V3 currently rejects
`ram-overlay` explicitly. For legacy generation-v1 stores without a
realization binding, layer contents and tombstones are still applied to the
tmpfs upper. A tombstone is applied before its corresponding layer, allowing a
package update to remove an old path and recreate it in the same transaction.

An empty state image still enables the default persistent machine identity and
logs. Supply an identity configuration to disable or customize those defaults:

```sh
scripts/build-state-image.sh \
  --identity-config persist/identity.example.conf \
  out/volatoo-state.ext4
```

Embed a persistence policy for testing:

```sh
scripts/build-state-image.sh \
  --config persist/example.conf \
  out/volatoo-policy-state.ext4
```

Attach it to an interactive QEMU boot:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-state.ext4 \
VOLATOO_STATE_REQUIRED=yes \
scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

### Declarative path policies

The optional state file `/volatoo/config/persist.conf` contains exactly three
whitespace-separated fields per policy:

```text
policy  absolute-target  storage-key
```

The supported policies are:

- `bind`: seed a state-backed directory from the image once, then bind-mount it
  at the target;
- `overlay`: keep the image directory as the lower layer and persist its
  OverlayFS upper/work directories;
- `sync`: restore the latest complete generation before init, and snapshot the
  path manually or during a normal OpenRC shutdown.

For example:

```text
bind     /home      home
overlay  /var/lib   var-lib
sync     /etc       etc
```

The file is parsed as data and is never sourced as shell code. Before creating
or mounting anything, the initramfs validates the complete configuration,
rejecting malformed lines, symbolic-link targets, protected early-boot paths,
duplicate keys, and overlapping targets. See
[`docs/design/persistence-policy.md`](../docs/design/persistence-policy.md) for
the complete grammar, storage layout, and lifecycle rules.

`/etc` uses a three-way merge across image updates: the previous pristine
image tree is the base, the last synchronized machine tree is local, and the
new image tree is new. Conflicts keep the local file live and stage the image
version using Gentoo's `._cfgNNNN_` convention. The rationale, deletion rules,
state generations, and failure behavior are recorded in
[`docs/design/etc-merge.md`](../docs/design/etc-merge.md).

Sync policies require `VOLATOO_IMAGE_SHA256`: the verified digest names the
pristine merge base. During the handoff, the initramfs publishes that digest
and invokes the early restore wrapper before the configured real init. Manual
operations in the running system are:

```sh
volatoo-persist status
volatoo-persist sync
```

The installed OpenRC service starts in the default runlevel and synchronizes
while that runlevel is stopped. Its `localmount` dependency makes the snapshot
finish before the state filesystem is unmounted.

### Default machine identity and logs

When state is available, the early userspace handoff also runs
`volatoo-identity apply` before the configured real init. On first boot it:

- generates a 32-character machine-id and stores it immediately;
- removes any image-provided SSH host keys, runs `ssh-keygen -A`, and stores
  the new machine-specific keys immediately;
- seeds a state-backed log directory and bind-mounts it at `/var/log`.

Subsequent boots restore the same machine-id and SSH keys and remount the same
logs. This path does not depend on a clean shutdown. If an explicit
`persist.conf` target overlaps `/var/log`, the explicit policy wins and the
default log bind is skipped.

All three defaults are enabled when
`/volatoo/config/identity.conf` is absent. They can be disabled independently:

```text
machine-id      no
ssh-host-keys   no
logs            no
```

The complete lifecycle, state layout, safety rules, and plaintext-key caveat
are documented in
[`docs/design/machine-identity.md`](../docs/design/machine-identity.md).

## Image integrity

When `VOLATOO_IMAGE_SHA256` is set for a direct image, the initramfs calculates
the image SHA-256 before mounting its SquashFS and before copying files into
the new root. For a filesystem or ISO container it hashes the internal
SquashFS file; for a raw SquashFS device it hashes the device contents.
Realization-v1 generations use the same eager check. Realization-v2 and v3
`store-overlay` and `copy` roots instead authenticate requested blocks with
dm-verity. Realization-v2 `ram-overlay` deliberately hashes the copied RAM
snapshot eagerly before releasing its source; v3 does not yet support that
mode.

The expected value must contain exactly 64 lowercase hexadecimal characters.
An empty value permits boot with a warning, which is useful during development
but should not be used in a release configuration. A mismatch stops the boot
with the stable `image.integrity` error code and prints both the expected and
actual digests in the rescue diagnostics.

For example, use the checksum generated by the stage3 builder:

```sh
image_sha256=$(awk '{print $1}' out/volatoo-stage3.squashfs.sha256)
VOLATOO_IMAGE_SHA256=$image_sha256 scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

SHA-256 and dm-verity detect corruption relative to their configured digest or
root hash. The realization signature now authenticates that complete binding
against an initramfs-embedded release key. Secure Boot is still required to
authenticate the initramfs and key themselves. Signed rollback is intentional;
preventing replay of an old valid release requires separately protected
monotonic state. See
[`docs/design/release-trust.md`](../docs/design/release-trust.md).

## Automated BIOS and UEFI boot test

The boot harness starts two QEMU guests, first with legacy BIOS on the `pc`
machine and then with EDK2 UEFI on `q35`. Each guest verifies the configured
image digest, reaches the Gentoo userspace, checks the root filesystem type,
prints a test marker, and powers off:

```sh
scripts/test-qemu-boot.sh /path/to/bzImage
```

The default inputs are `out/volatoo-initramfs.cpio.gz` and
`out/volatoo-stage3.squashfs`. They can be supplied explicitly:

```sh
scripts/test-qemu-boot.sh \
  /path/to/bzImage \
  /path/to/initramfs.cpio.gz \
  /path/to/root.squashfs
```

The persistent `store-overlay` root is tested by default. A quick firmware and
handoff smoke test can select only BIOS:

```sh
VOLATOO_TEST_FIRMWARES=bios \
scripts/test-qemu-boot.sh /path/to/bzImage
```

The harness detects the EDK2/OVMF code and variables images from common QEMU
installation paths on macOS and Linux. Set `VOLATOO_UEFI_FIRMWARE` and
`VOLATOO_UEFI_VARS` when they are installed elsewhere. A development kernel
whose boot drivers are modules also needs an initramfs containing that kernel's
module tree; the target Volatoo kernel will build the required drivers in.
`VOLATOO_TEST_FIRMWARES` accepts `bios`, `uefi`, or the default `bios,uefi`.
`VOLATOO_QEMU_ACCEL=kvm` selects native Linux KVM acceleration; TCG remains the
portable default. The matching default CPU models are `host` and `max`
respectively, and `VOLATOO_QEMU_CPU` can override them.

`scripts/test-qemu-boot-docker.sh` exposes the same boot-test interface through
a pinned Debian QEMU/OVMF container. It is the portable choice when QEMU must
run inside the selected Docker context. The optional state image and metrics
output are the only writable input mounts, and QEMU uses TCG inside the
container.

Set `VOLATOO_TEST_METRICS_FILE` to append successful boots to a versioned TSV.
Shell boots include guest `MemTotal`, `MemAvailable`, and root filesystem
usage. Every row also records the host CPU, host kernel, QEMU version,
accelerator, VM memory, firmware, root mode, init system, elapsed time, and
input image size. Metrics v4 additionally separates the root-authentication
stage, the `switch_root` handoff, PID 1 startup, an optional fixture-owned
service-readiness marker, a late service milestone, userspace readiness, and
the complete measured lifecycle. The late milestone is `Multi-User System` for
systemd and `Starting local` for OpenRC. Set `VOLATOO_TEST_SERVICE_READY=yes`
for QEMU fixtures that install the test-only readiness service; production
images do not install it. The Docker runner bind-mounts the requested metrics
file so these measurements remain available when QEMU runs through OrbStack.

The native root-mode performance comparison must run on an x86_64 Linux host
with read-write KVM access:

```sh
scripts/measure-native-root-modes.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-minimal-systemd.squashfs \
  out/native-root-mode-metrics.tsv
```

It runs shell and systemd boots for `store-overlay`, `ram-overlay`, and `copy`.
Both overlay modes must stay within the boot limit, be no slower than copy, and
retain at least 512 MiB more guest `MemAvailable`. The release record still
needs results from named reference hardware. The script rejects non-x86_64 and
non-KVM hosts instead of treating emulation as native evidence.

When `VOLATOO_STATE_IMAGE` is set, the harness attaches it as a writable second
virtio block device, requires discovery by default, and verifies the versioned
state mount after the userspace handoff:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-state.ext4 \
VOLATOO_TEST_ROOT_MODE=store-overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

With a state image built from `persist/example.conf`, enable the policy test.
The BIOS guest writes markers through the bind, overlay, and sync policies,
runs a manual sync, and the UEFI guest verifies that all three survived:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-policy-state.ext4 \
VOLATOO_TEST_POLICIES=yes \
VOLATOO_TEST_ROOT_MODE=store-overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

An empty state image exercises the identity defaults independently. The BIOS
guest records its machine-id and ED25519 host public key in persistent logs;
the UEFI guest compares both and verifies the log survived:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-state.ext4 \
VOLATOO_TEST_IDENTITY=yes \
VOLATOO_TEST_ROOT_MODE=store-overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

To exercise the OpenRC shutdown hook instead of the manual sync, make the BIOS
guest boot the real init and power off normally. The harness requires evidence
that `/etc` was synchronized before continuing to the UEFI restore check:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-policy-state.ext4 \
VOLATOO_TEST_POLICIES=yes \
VOLATOO_TEST_SHUTDOWN_SYNC=yes \
VOLATOO_TEST_ROOT_MODE=store-overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

## Failure and rescue behavior

Fatal boot errors use stable, dotted error codes such as `image.not-found`,
`image.file-not-found`, `image.integrity`, `state.not-found`,
`state.layout-version`, `persist.config`, `persist.overlay-mount`,
`identity.helper-missing`, and `root.init-missing`. Before opening a rescue
shell, the initramfs prints:

- the error code and human-readable reason;
- the kernel command line and effective Volatoo settings;
- `/proc/partitions` and `blkid` output;
- all mounts created before the failure.

The rescue environment includes `blkid`, `ls`, `dmesg`, `tail`, mount tools,
and forced poweroff/reboot commands. It remains intentionally small and uses
only the single static BusyBox executable already required by early userspace.
The shell owns the console as its controlling terminal, and exiting it
accidentally starts a fresh rescue shell instead of terminating PID 1.

The QEMU helper defaults to an interactive stage3 Bash so the handoff can be
inspected directly. To test the stock OpenRC init instead:

```sh
VOLATOO_TARGET_INIT=/sbin/init scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

Release images do not enable an automatic root login. The test harness can
therefore validate an init system non-interactively by waiting for its serial
login prompt and PID 1 marker, then exiting QEMU without modifying the image:

```sh
VOLATOO_TEST_INIT_SYSTEM=openrc scripts/test-qemu-boot.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-minimal-openrc.squashfs

VOLATOO_TEST_INIT_SYSTEM=systemd \
VOLATOO_TEST_ROOT_MODE=store-overlay \
scripts/test-qemu-boot.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-minimal-systemd.squashfs
```

`shell` remains the default `VOLATOO_TEST_INIT_SYSTEM` value. The init-system
mode checks both BIOS and UEFI. It is intentionally separate from the
interactive persistence-policy and shutdown-sync tests.

The default keeps the immutable SquashFS on its source storage:

```sh
VOLATOO_ROOT_MODE=store-overlay scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

To copy only the compressed SquashFS into RAM, release the source image, and
use a separate tmpfs write layer:

```sh
VOLATOO_ROOT_MODE=ram-overlay scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

The old spelling is retained as a compatibility alias:

```sh
VOLATOO_ROOT_MODE=overlay scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-stage3.squashfs
```

The QEMU helper can expose a filesystem or ISO image as USB storage:

```sh
VOLATOO_IMAGE_BUS=usb \
VOLATOO_IMAGE='LABEL=VOLATOO-BOOT' \
VOLATOO_IMAGE_FILE=/volatoo/root.squashfs \
VOLATOO_ROOT_MODE=ram-overlay \
scripts/run-phase0-qemu.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  /path/to/volatoo-boot.iso
```

For this VM-only prototype, the Docker build enables root auto-login on
`ttyS0`. This makes successful OpenRC completion observable in a headless QEMU
session. It is explicitly a test setting and must not appear in a release
image.

The successful full-copy handoff markers are:

```text
[volatoo] root copy completed in ...s
[volatoo] switching to copy root; init=...
```

The default mode reports `immutable store overlay root ready` and switches to
a `store-overlay` root. Its read-only lower and tmpfs writable backing are
visible below `/.volatoo/`. The RAM-backed mode reports
`RAM-backed overlay root ready` and switches to a
`ram-overlay` root. Its read-only compressed image is visible under
`/.volatoo/ram-lower`, while runtime writes live below
`/.volatoo/writable`. The compatibility alias reports
`legacy overlay root ready`.

Inside the diagnostic shell, `/proc/mounts` should report `/` as `tmpfs` for
copy mode or `overlay` for every overlay mode, and `/etc/gentoo-release`
should identify Gentoo. Run `poweroff -f` to stop the VM. With QEMU's
`-nographic` console, Ctrl-A followed by X also exits the emulator.

The helper assigns 8 GiB by default. The tested stage3 does fit in a 4 GiB VM,
but leaves only about 284 MiB free after the tmpfs copy, which is not useful for
normal operation. `VOLATOO_VM_MEMORY` can override the default.

## Scope

Phase 1 is complete: the generator covers embedded configuration, block-device
discovery, SHA-256 integrity verification, reliable rescue diagnostics, and a
one-command BIOS/UEFI test harness. Phase 2 has added the versioned
`VOLATOO-STATE` filesystem layout, optional/required discovery semantics, and
validated declarative bind, overlay, and sync policies. Phase 3U adds complete
and incremental FHS-compatible system realizations, a host-read-only system
store, and dm-verity authenticated lazy reads. Full reachable-object hashing
is an import/scrub operation. Exact realization plans are authenticated by
initramfs-embedded Ed25519 release keys. Secure Boot and rollback freshness
remain outside this boundary.
