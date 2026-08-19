# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

RUN apk add --no-cache \
    bash=5.3.9-r1 \
    coreutils=9.11-r0 \
    grub=2.14-r0 \
    grub-bios=2.14-r0 \
    grub-efi=2.14-r0 \
    mtools=4.0.49-r0 \
    python3=3.14.7-r0 \
    signify=32-r1 \
    squashfs-tools=4.7.5-r0 \
    xorriso=1.5.8-r0

COPY --chmod=0755 image/live-iso/container/build-live-iso.sh \
    /usr/local/sbin/build-volatoo-live-iso
COPY --chmod=0755 image/live-iso/container/verify-inputs.py \
    /usr/local/sbin/verify-volatoo-live-inputs
COPY --chmod=0755 image/live-iso/container/normalize-iso.py \
    /usr/local/sbin/normalize-volatoo-live-iso

ENTRYPOINT ["/usr/local/sbin/build-volatoo-live-iso"]
