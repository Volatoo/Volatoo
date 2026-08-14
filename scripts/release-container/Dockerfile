# syntax=docker/dockerfile:1.7

FROM --platform=linux/amd64 alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

RUN apk add --no-cache \
    bash \
    binutils=2.45.1-r1 \
    coreutils \
    dosfstools \
    e2fsprogs \
    e2fsprogs-extra \
    grub \
    grub-bios \
    grub-efi \
    libfaketime=0.9.12-r0 \
    sbsigntool=0.9.5-r3 \
    sgdisk \
    systemd-efistub=260.2-r0 \
    util-linux

COPY --chmod=0755 scripts/release-container/build-release-disk.sh \
    /usr/local/sbin/build-volatoo-release-disk

ENTRYPOINT ["/usr/local/sbin/build-volatoo-release-disk"]
