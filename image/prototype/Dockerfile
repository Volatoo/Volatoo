# syntax=docker/dockerfile:1.7

ARG GENTOO_IMAGE=gentoo/stage3:latest

FROM --platform=${TARGETPLATFORM} ${GENTOO_IMAGE} AS stage3

FROM --platform=${BUILDPLATFORM} alpine:3.24 AS squashfs-builder

# mksquashfs is the only added binary: it converts the stage3 filesystem into
# the compressed image consumed by the Volatoo initramfs.
RUN apk add --no-cache squashfs-tools

ARG ZSTD_LEVEL=19
ARG BUILD_NONCE=default

COPY --from=stage3 / /rootfs

# The OCI source identifies itself to OpenRC as a Docker container. Volatoo
# boots on a kernel, so remove that source-image setting before compression.
RUN sed -i '/^rc_sys="docker"$/d' /rootfs/etc/rc.conf \
    && ! grep -Fqx 'rc_sys="docker"' /rootfs/etc/rc.conf

# Phase 0 is VM-only. Auto-login on QEMU's serial console makes completion of
# the stock OpenRC boot observable; release images must not carry this setting.
RUN sed -i \
        's|^#s0:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100$|s0:12345:respawn:/sbin/agetty --autologin root -L 115200 ttyS0 vt100|' \
        /rootfs/etc/inittab \
    && grep -Fqx \
        's0:12345:respawn:/sbin/agetty --autologin root -L 115200 ttyS0 vt100' \
        /rootfs/etc/inittab

COPY --chmod=0755 persist/volatoo-persist /rootfs/usr/sbin/volatoo-persist
COPY --chmod=0755 persist/volatoo-identity /rootfs/usr/sbin/volatoo-identity
COPY --chmod=0755 persist/volatoo-persist-early /rootfs/usr/libexec/volatoo-persist-early
COPY --chmod=0755 persist/volatoo-persist.initd /rootfs/etc/init.d/volatoo-persist

RUN ln -s /etc/init.d/volatoo-persist \
        /rootfs/etc/runlevels/default/volatoo-persist

RUN mkdir /output \
    && test -n "${BUILD_NONCE}" \
    && mksquashfs /rootfs /output/volatoo-stage3.squashfs \
        -noappend \
        -comp zstd \
        -Xcompression-level "${ZSTD_LEVEL}" \
        -b 1M \
        -no-progress

FROM scratch AS artifact

COPY --from=squashfs-builder /output/volatoo-stage3.squashfs /
