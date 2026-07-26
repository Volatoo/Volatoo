# syntax=docker/dockerfile:1.7

FROM amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

# SquashFS construction and compaction are isolated from the selected Gentoo
# root. The extra metadata tools verify numeric ownership, ACLs and xattrs
# across the compaction round trip.
RUN apk add --no-cache \
    acl \
    attr \
    coreutils \
    squashfs-tools=4.7.5-r0

COPY --chmod=0755 update/layer-container/compress-layer.sh \
    /usr/local/sbin/compress-volatoo-layer
COPY --chmod=0755 update/layer-container/compact-generation.sh \
    /usr/local/sbin/compact-volatoo-generation

ENTRYPOINT ["/usr/local/sbin/compress-volatoo-layer"]
