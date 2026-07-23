# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GENTOO_IMAGE=gentoo/stage3@sha256:b5317fd2127e15ace5ff7a2c8aab1ed37a22736a8218546f3b00b4d94b78e500
ARG PORTAGE_IMAGE=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8

FROM ${PORTAGE_IMAGE} AS portage

FROM ${GENTOO_IMAGE} AS catalyst-installer

ARG CATALYST_VERSION=4.1.1-r1

COPY --from=portage /var/db/repos/gentoo /var/db/repos/gentoo

RUN printf '=dev-util/catalyst-%s ~amd64\n' "${CATALYST_VERSION}" \
        > /etc/portage/package.accept_keywords/catalyst \
    && printf '%s\n' \
        'dev-util/catalyst -iso -qcow2' \
        'sys-apps/util-linux python' \
        'sys-fs/squashfs-tools zstd' \
        > /etc/portage/package.use/volatoo-catalyst \
    && emerge --verbose --oneshot --getbinpkg=y \
        "=dev-util/catalyst-${CATALYST_VERSION}" \
        sys-fs/squashfs-tools \
    && rm -rf /var/db/repos/gentoo /var/cache/distfiles/*

# Keep the final builder free of the temporary Portage tree used above.
FROM ${GENTOO_IMAGE}

COPY --from=catalyst-installer / /

# pyDeComp 0.3 has xz/gzip SquashFS definitions but no Zstd definition. Python
# loads sitecustomize before Catalyst, so extend the upstream map without
# replacing the packaged module. Level 19 is Volatoo's measured image policy.
ENV PYTHONPATH=/usr/local/lib/volatoo-python

COPY image/catalyst/container/sitecustomize.py \
    /usr/local/lib/volatoo-python/sitecustomize.py

RUN python -c \
    'from DeComp.definitions import COMPRESS_DEFINITIONS as d; a=d["squashfs_zstd"][2]; assert a[a.index("-Xcompression-level")+1] == "19"'

COPY --chmod=0755 image/catalyst/container/run-catalyst.sh \
    /usr/local/sbin/run-volatoo-catalyst

ENTRYPOINT ["/usr/local/sbin/run-volatoo-catalyst"]
