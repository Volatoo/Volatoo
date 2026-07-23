# Catalyst image build

The Phase 3 `minimal` image is a Catalyst `stage4` built from three explicit
inputs:

1. an official amd64 OpenRC stage3 archive;
2. its matching Gentoo repository snapshot in Catalyst SquashFS format;
3. the version and snapshot identifiers passed on the command line.

The build itself runs in a privileged amd64 Docker container, so the host does
not need Gentoo, Catalyst, Portage, or SquashFS tools. Privilege is confined to
the disposable build container. The default Gentoo stage3 and Portage OCI
inputs used to assemble that builder are pinned by manifest digest; the
`VOLATOO_GENTOO_IMAGE` and `VOLATOO_PORTAGE_IMAGE` overrides are available for
an intentional toolchain refresh.

Catalyst needs to create device nodes while unpacking a stage3. Its chroot and
caches therefore live in the `volatoo-catalyst-work` Docker named volume rather
than a host bind mount. This is required on macOS and keeps Linux-specific
intermediate state out of the checkout. Set `--work-volume` to use a separate
cache or build in isolation.

```sh
scripts/build-catalyst-squashfs.sh \
  --stage3 /path/to/stage3-amd64-openrc-20260719T170103Z.tar.xz \
  --snapshot /path/to/gentoo-20260719.xz.sqfs \
  --snapshot-id 20260719 \
  --version 20260723 \
  out/volatoo-minimal-20260723.squashfs
```

Use source files whose checksums have been verified against Gentoo's signed
download metadata. Keeping the source filenames, snapshot ID, image version,
and resulting `.sha256` together makes a build repeatable. Catalyst work,
distfile, and binary-package caches persist in the selected Docker volume; only
the final SquashFS and checksum are exported to the host.

For a quick structural check that does not require source archives or run a
Catalyst build:

```sh
scripts/build-catalyst-squashfs.sh --validate-only
```

The validation uses the same container and Catalyst version as a real build.
It parses the rendered spec, verifies its required stage4 fields and package
set, and confirms that the builder's pyDeComp extension supplies SquashFS Zstd
at level 19.

## Validated input set

The first end-to-end build was completed on 2026-07-23 with Catalyst
`4.1.1-r1` and these Gentoo inputs:

| Input | Digest |
|---|---|
| `stage3-amd64-openrc-20260719T170103Z.tar.xz` | SHA-256 `c333a3b4c1b89360290c8242f9d397ca0dc5ac683fd52ad251f0a5845a7e5a70` |
| `gentoo-20260719.xz.sqfs` | SHA-512 `e3d1b5f267cf9b851094ac094d5510b3625fde3c05cd15f58b5d6c61ad4a5e4166438074234ebde976eca3c1da0a18eca1aa673b3c74484503a47dbd991fccbc` |

Both digests and their OpenPGP signatures were verified against Gentoo's
release keys before the build. The resulting image was 574,853,120 bytes and
used SquashFS Zstd level 19 with 1 MiB blocks. Built images remain ignored
artifacts; the table records the known-good source set rather than publishing
a release image.
