FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        cpio \
        file \
        grep \
        gzip \
        openssh-client \
        ovmf \
        qemu-system-x86 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
