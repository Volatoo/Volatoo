# syntax=docker/dockerfile:1.7

FROM amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

# SquashFS construction and compaction are isolated from the selected Gentoo
# root. The extra metadata tools verify numeric ownership, ACLs and xattrs
# across the compaction round trip. pax-utils validates ELF interpreters and
# runtime search paths without executing target binaries. GNU find emits one
# symlink graph report without spawning readlink once per target-root link.
# cryptsetup supplies veritysetup so realization publishes a deterministic
# dm-verity tree alongside the SquashFS closure. signify and Python provide
# the host-neutral, post-build release-signing command; neither enters the
# realized Gentoo filesystem.
RUN apk add --no-cache \
    acl \
    attr \
    coreutils \
    cryptsetup=2.8.6-r0 \
    findutils \
    pax-utils \
    python3 \
    signify=32-r1 \
    squashfs-tools=4.7.5-r0

COPY --chmod=0755 update/layer-container/compress-layer.sh \
    /usr/local/sbin/compress-volatoo-layer
COPY --chmod=0755 update/layer-container/materialize-generation.sh \
    /usr/local/sbin/materialize-volatoo-generation
COPY --chmod=0755 update/layer-container/validate-fhs.sh \
    /usr/local/sbin/validate-volatoo-fhs
COPY --chmod=0755 update/layer-container/index-fhs-tree.sh \
    /usr/local/sbin/index-volatoo-fhs-tree
COPY --chmod=0755 update/layer-container/validate-fhs-index.sh \
    /usr/local/sbin/validate-volatoo-fhs-index
COPY update/layer-container/validate-fhs-index.py \
    /usr/local/libexec/validate-volatoo-fhs-index.py
COPY update/layer-container/fhs_index.py \
    /usr/local/libexec/fhs_index.py
COPY update/layer-container/fhs_index.py \
    /usr/local/sbin/fhs_index.py
COPY update/layer-container/validate-elf-closure.awk \
    /usr/local/libexec/validate-volatoo-elf-closure.awk
COPY --chmod=0755 update/layer-container/merge-fhs-index.py \
    /usr/local/sbin/merge-volatoo-fhs-index
COPY --chmod=0755 update/layer-container/compact-generation.sh \
    /usr/local/sbin/compact-volatoo-generation
COPY --chmod=0755 update/layer-container/prepare-incremental-realization.sh \
    /usr/local/sbin/prepare-volatoo-incremental-realization

ENTRYPOINT ["/usr/local/sbin/compress-volatoo-layer"]
