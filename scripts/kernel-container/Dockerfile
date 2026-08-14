# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bc \
        binutils-x86-64-linux-gnu \
        bison \
        ca-certificates \
        curl \
        dwarves \
        flex \
        gcc-x86-64-linux-gnu \
        libelf-dev \
        libssl-dev \
        make \
        perl \
        python3 \
        rsync \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Kernel builds use the cross compiler for target objects and the native
# compiler for host utilities such as fixdep and objtool.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 scripts/kernel-container/build-kernel /usr/local/sbin/build-volatoo-kernel

ENTRYPOINT ["/usr/local/sbin/build-volatoo-kernel"]
