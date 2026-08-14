# syntax=docker/dockerfile:1.7

FROM --platform=linux/amd64 alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

RUN apk add --no-cache \
    bash \
    coreutils \
    dosfstools \
    e2fsprogs \
    e2fsprogs-extra \
    grub \
    grub-bios \
    grub-efi \
    sgdisk \
    util-linux

COPY --chmod=0755 scripts/release-container/build-release-disk.sh \
    /usr/local/sbin/build-volatoo-release-disk

ENTRYPOINT ["/usr/local/sbin/build-volatoo-release-disk"]
