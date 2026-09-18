# syntax=docker/dockerfile:1.7

FROM --platform=linux/amd64 alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

# Every package is pinned to an exact Alpine 3.24.1 build. The pinned base
# image digest fixes the repository branch; these version pins make package
# resolution deterministic so tool drift breaks the build loudly instead of
# changing the output silently.
RUN apk add --no-cache \
    bash=5.3.9-r1 \
    binutils=2.45.1-r1 \
    coreutils=9.11-r0 \
    dosfstools=4.2-r2 \
    e2fsprogs=1.47.4-r0 \
    e2fsprogs-extra=1.47.4-r0 \
    grub=2.14-r0 \
    grub-bios=2.14-r0 \
    grub-efi=2.14-r0 \
    libfaketime=0.9.13-r0 \
    mtools=4.0.49-r0 \
    sbsigntool=0.9.5-r3 \
    sgdisk=1.0.10-r1 \
    systemd-efistub=260.2-r0 \
    util-linux=2.42.3-r1

COPY --chmod=0755 scripts/release-container/build-release-disk.sh \
    /usr/local/sbin/build-volatoo-release-disk

ENTRYPOINT ["/usr/local/sbin/build-volatoo-release-disk"]
