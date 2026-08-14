# syntax=docker/dockerfile:1.7

FROM --platform=linux/amd64 alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f

RUN apk add --no-cache \
    bash \
    coreutils \
    zstd=1.5.7-r2

COPY --chmod=0755 scripts/publication-container/package-release.sh \
    /usr/local/sbin/package-volatoo-release

ENTRYPOINT ["/usr/local/sbin/package-volatoo-release"]
