# Catalyst image build

Each Phase 3 `minimal` image is a Catalyst `stage4` built from five explicit
inputs:

1. the selected `openrc` or `systemd` target;
2. the matching official amd64 stage3 archive;
3. its matching Gentoo repository snapshot in Catalyst SquashFS format;
4. one or more release public keys;
5. the version and snapshot identifiers passed on the command line.

OpenRC uses `default/linux/amd64/23.0`; systemd uses
`default/linux/amd64/23.0/systemd`. They use separate Catalyst work volumes and
produce separately named images. The script rejects a stage3 filename that
does not match the selected init system.

`package-sets/minimal` contains the shared runtime. Init-specific additions
live in `minimal-openrc` and `minimal-systemd`; the OpenRC target adds
sysklogd, while the systemd target uses the journald already supplied by its
stage3.

The build itself runs in a privileged amd64 Docker container, so the host does
not need Gentoo, Catalyst, Portage, or SquashFS tools. Privilege is confined to
the disposable build container. The default Gentoo stage3 and Portage OCI
inputs used to assemble that builder are pinned by manifest digest; the
`VOLATOO_GENTOO_IMAGE` and `VOLATOO_PORTAGE_IMAGE` overrides are available for
an intentional toolchain refresh.

Catalyst needs to create device nodes while unpacking a stage3. Its chroot and
caches therefore live in the existing `volatoo-catalyst-work` OpenRC volume or
the separate `volatoo-catalyst-work-systemd` volume rather than a host bind
mount. This is required on macOS and keeps Linux-specific intermediate state
out of the checkout. Set `--work-volume` to use a separate cache or build in
isolation.

```sh
scripts/build-catalyst-squashfs.sh \
  --init-system openrc \
  --stage3 /path/to/stage3-amd64-openrc-20260719T170103Z.tar.xz \
  --snapshot /path/to/gentoo-20260719.xz.sqfs \
  --snapshot-id 20260719 \
  --trust-key /secure/volatoo-release.pub \
  --version 20260723 \
  out/volatoo-minimal-openrc-20260723.squashfs
```

The equivalent systemd build is:

```sh
scripts/build-catalyst-squashfs.sh \
  --init-system systemd \
  --stage3 /path/to/stage3-amd64-systemd-20260719T170103Z.tar.xz \
  --snapshot /path/to/gentoo-20260719.xz.sqfs \
  --snapshot-id 20260719 \
  --trust-key /secure/volatoo-release.pub \
  --version 20260723 \
  out/volatoo-minimal-systemd-20260723.squashfs
```

Use source files whose checksums have been verified against Gentoo's signed
download metadata. Keeping the source filenames, snapshot ID, image version,
and resulting `.sha256` together makes a build repeatable. Catalyst work,
distfile, and binary-package caches persist in the selected Docker volume; only
the final SquashFS and checksum are exported to the host.

For a quick structural check that does not require source archives or run a
Catalyst build:

```sh
scripts/build-catalyst-squashfs.sh --init-system openrc --validate-only
scripts/build-catalyst-squashfs.sh --init-system systemd --validate-only
```

The validation uses the same container and Catalyst version as a real build.
It parses the rendered spec, verifies its required stage4 fields and package
set, and confirms that the builder's pyDeComp extension supplies SquashFS Zstd
at level 19.

The shared minimal package set installs Gentoo's native `app-crypt/signify`
from the verified repository snapshot. Keeping the installed userspace on one
glibc ABI lets realization validation cover the verifier itself instead of
exempting a private musl runtime. Catalyst executes the verifier during
finalization. Trusted keys are installed by SHA-256 below
`/etc/volatoo/trusted.d`; use the same key set when building the initramfs.
Omitting `--trust-key` remains available for unsigned development images, but
those images cannot perform authenticated generation selection from the
installed userspace.

## Weekly CI build

The `Weekly minimal image` GitHub Actions workflow runs every Monday and can
also be started manually. Pull requests and relevant pushes only run its
metadata, shell, builder, and spec validation job; scheduled and manual runs
additionally build both full init-system targets and retain them as separate
workflow artifacts for 14 days.

The workflow does not trust mutable `current` downloads. It uses
`scripts/fetch-gentoo-inputs.sh` to verify the clearsigned stage3 pointer and
snapshot checksum index against the expected Gentoo release fingerprints,
then verifies each downloaded payload with SHA-512. The uploaded artifact
contains the SquashFS, its SHA-256 file, and a build manifest recording the
source URLs, upstream digests, repository commit, and workflow run.

Resolve and verify current metadata locally without downloading the payloads:

```sh
scripts/fetch-gentoo-inputs.sh \
  --init-system openrc \
  --metadata-only \
  out/gentoo-inputs-openrc

scripts/fetch-gentoo-inputs.sh \
  --init-system systemd \
  --metadata-only \
  out/gentoo-inputs-systemd
```

## Validated input set

The first OpenRC and systemd builds were completed on 2026-07-23 with Catalyst
`4.1.1-r1` and these Gentoo inputs:

| Input | Digest |
|---|---|
| `stage3-amd64-openrc-20260719T170103Z.tar.xz` | SHA-256 `c333a3b4c1b89360290c8242f9d397ca0dc5ac683fd52ad251f0a5845a7e5a70` |
| `stage3-amd64-systemd-20260719T170103Z.tar.xz` | SHA-512 `bd9b0bb3bc4908671b986dec12a7e831b313e19c4e0a8cbf866c31d3c5106ca39794b9335c9290a97d9d59bb9c93e28530431e782496c32415ce1d823dd56d78` |
| `gentoo-20260719.xz.sqfs` | SHA-512 `e3d1b5f267cf9b851094ac094d5510b3625fde3c05cd15f58b5d6c61ad4a5e4166438074234ebde976eca3c1da0a18eca1aa673b3c74484503a47dbd991fccbc` |
| `gentoo-20260722.xz.sqfs` | SHA-512 `f84d35e9b169a307af358d0c76b46a18124534418ab132975cbef759dd6278c6b51d25e256317fd36af9097eb1146f2d3872cb1fd05596443e788b27a22e8b19` |

All upstream digests and their OpenPGP signatures were verified against Gentoo's
release keys before each build. The first OpenRC image was 574,853,120 bytes.
The systemd r2 image was 598,401,024 bytes with SHA-256
`29632a44f6b2c10d0ca8affcb1e71fe2e18f2c226bee05ffd08258d44f319b52`.
Both use SquashFS Zstd level 19 with 1 MiB blocks.

The OpenRC r2 image reached its serial login under BIOS and UEFI in the
overlay-root QEMU lane in 23 and 35 seconds. The systemd r2 image passed the
same lanes in 34 and 36 seconds. The full-copy lane remains a separate
performance Gate: under TCG, copying the roughly 2.6 GiB expanded systemd root
exceeded the short validation window before PID 1 started. Built images remain
ignored artifacts; these values record known-good local evidence rather than
publishing a release image.
