# Volatoo initramfs

The standalone generator builds the early userspace that locates a Gentoo
SquashFS image, copies it into tmpfs, and uses `switch_root` to start the
stage3 userspace. The Phase 0 QEMU helper remains the current test harness.

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
scripts/build-initramfs.sh --busybox /path/to/busybox
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
  --config /path/to/initramfs.conf \
  --output out/custom-initramfs.cpio.gz
```

The supported settings are:

| Setting | Default | Purpose |
|---|---|---|
| `VOLATOO_IMAGE` | `/dev/vda` | `/dev/...`, `LABEL=...`, or `UUID=...` |
| `VOLATOO_IMAGE_FILE` | empty | SquashFS path inside a filesystem or ISO |
| `VOLATOO_IMAGE_SHA256` | empty | Expected lowercase SHA-256 digest |
| `VOLATOO_INIT` | `/sbin/init` | Program executed after `switch_root` |
| `VOLATOO_ROOT_MODE` | `copy` | `copy`, or the experimental `overlay` |
| `VOLATOO_TMPFS_SIZE` | `80%` | Percentage of RAM allowed for the tmpfs |
| `VOLATOO_STATE` | `LABEL=VOLATOO-STATE` | State device spec, or `none` |
| `VOLATOO_STATE_REQUIRED` | `no` | Whether missing state is a boot failure |
| `VOLATOO_GENERATION` | `auto` | `auto`, `previous`, `none`, or a digest |

Kernel parameters `volatoo.image=`, `volatoo.image-file=`,
`volatoo.image-sha256=`, `volatoo.init=`, `volatoo.root=`, and
`volatoo.tmpfs-size=`, `volatoo.state=`, `volatoo.state-required=`, and
`volatoo.generation=` override the embedded settings for one boot.

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
plan, build context, base, ordered layer, tombstone and transaction objects
before changing `/newroot`. A rejected current generation falls back to a
fully verified `previous`. `VOLATOO_GENERATION=previous`, `none`, or an
explicit digest provides deterministic recovery behavior.

For copy roots, the verified base and each layer are copied into the root
tmpfs. For overlay roots, the base remains the read-only lower filesystem and
layer contents plus tombstones are applied to the tmpfs upper layer. A
tombstone is applied before its corresponding layer, allowing a package update
to remove an old path and recreate it in the same transaction.

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

When `VOLATOO_IMAGE_SHA256` is set, the initramfs calculates the image SHA-256
before mounting its SquashFS and before copying files into the new root. For a
filesystem or ISO container it hashes the internal SquashFS file; for a raw
SquashFS device it hashes the device contents.

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

SHA-256 detects accidental corruption, but it does not prove authenticity when
an attacker can replace both the image and its configured digest. Signed
manifests are a possible future hardening step.

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

The supported full-copy root is tested by default. Cross-architecture TCG
emulation can make that test slow, so a quick firmware and handoff smoke test
can use the experimental overlay:

```sh
VOLATOO_TEST_ROOT_MODE=overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

The harness detects the EDK2/OVMF code and variables images from common QEMU
installation paths on macOS and Linux. Set `VOLATOO_UEFI_FIRMWARE` and
`VOLATOO_UEFI_VARS` when they are installed elsewhere. A development kernel
whose boot drivers are modules also needs an initramfs containing that kernel's
module tree; the target Volatoo kernel will build the required drivers in.

When `VOLATOO_STATE_IMAGE` is set, the harness attaches it as a writable second
virtio block device, requires discovery by default, and verifies the versioned
state mount after the userspace handoff:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-state.ext4 \
VOLATOO_TEST_ROOT_MODE=overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

With a state image built from `persist/example.conf`, enable the policy test.
The BIOS guest writes markers through the bind, overlay, and sync policies,
runs a manual sync, and the UEFI guest verifies that all three survived:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-policy-state.ext4 \
VOLATOO_TEST_POLICIES=yes \
VOLATOO_TEST_ROOT_MODE=overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

An empty state image exercises the identity defaults independently. The BIOS
guest records its machine-id and ED25519 host public key in persistent logs;
the UEFI guest compares both and verifies the log survived:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-state.ext4 \
VOLATOO_TEST_IDENTITY=yes \
VOLATOO_TEST_ROOT_MODE=overlay \
scripts/test-qemu-boot.sh /path/to/bzImage
```

To exercise the OpenRC shutdown hook instead of the manual sync, make the BIOS
guest boot the real init and power off normally. The harness requires evidence
that `/etc` was synchronized before continuing to the UEFI restore check:

```sh
VOLATOO_STATE_IMAGE=out/volatoo-policy-state.ext4 \
VOLATOO_TEST_POLICIES=yes \
VOLATOO_TEST_SHUTDOWN_SYNC=yes \
VOLATOO_TEST_ROOT_MODE=overlay \
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
VOLATOO_TEST_ROOT_MODE=overlay \
scripts/test-qemu-boot.sh \
  /path/to/bzImage \
  out/volatoo-initramfs.cpio.gz \
  out/volatoo-minimal-systemd.squashfs
```

`shell` remains the default `VOLATOO_TEST_INIT_SYSTEM` value. The init-system
mode checks both BIOS and UEFI. It is intentionally separate from the
interactive persistence-policy and shutdown-sync tests.

The full-copy root is the default. To boot the comparison layout, which keeps
the squashfs mounted and stores only changes in a tmpfs write layer:

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
VOLATOO_ROOT_MODE=overlay \
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
[volatoo] switching to tmpfs root; init=...
```

The overlay comparison reports `overlay root ready` and `switching to overlay
root`. Its backing mounts remain visible below `/.volatoo/` after handoff.

Inside the diagnostic shell, `/proc/mounts` should report `/` as `tmpfs`, and
`/etc/gentoo-release` should identify Gentoo. Run `poweroff -f` to stop the VM.
With QEMU's `-nographic` console, Ctrl-A followed by X also exits the emulator.

The helper assigns 8 GiB by default. The tested stage3 does fit in a 4 GiB VM,
but leaves only about 284 MiB free after the tmpfs copy, which is not useful for
normal operation. `VOLATOO_VM_MEMORY` can override the default.

## Scope

Phase 1 is complete: the generator covers embedded configuration, block-device
discovery, SHA-256 integrity verification, reliable rescue diagnostics, and a
one-command BIOS/UEFI test harness. Phase 2 has added the versioned
`VOLATOO-STATE` filesystem layout, optional/required discovery semantics, and
validated declarative bind, overlay, and sync policies. `/etc` will use a
three-way merge rather than blind snapshot restoration; the sync and merge
tooling is the next persistence deliverable. SHA-256 provides integrity but
not authenticity; signed manifests remain possible future hardening.
