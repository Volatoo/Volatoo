#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/prepare-verity-root-docker.sh OUTPUT_DIRECTORY

Export a pinned amd64 Alpine veritysetup runtime closure for
scripts/build-initramfs.sh --verity-root. OUTPUT_DIRECTORY must be absent or
empty. Docker is required; the host may be macOS or Linux.
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi
if (( $# != 1 )); then
	usage >&2
	exit 2
fi

output_dir=$1
if [[ -L $output_dir ]]; then
	echo "error: output directory must not be a symbolic link: $output_dir" >&2
	exit 1
fi
if [[ -e $output_dir && ! -d $output_dir ]]; then
	echo "error: output is not a directory: $output_dir" >&2
	exit 1
fi
mkdir -p "$output_dir"
if find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
	echo "error: output directory is not empty: $output_dir" >&2
	exit 1
fi
output_dir=$(cd -- "$output_dir" && pwd)

command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$output_dir,dst=/export" \
	amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f \
	sh -c '
		set -eu
		mkdir -p /rootfs/etc/apk
		cp -a /etc/apk/keys /rootfs/etc/apk/
		cp /etc/apk/repositories /rootfs/etc/apk/
		apk --root /rootfs \
			--initdb \
			--no-scripts \
			add --no-cache cryptsetup=2.8.6-r0 >/dev/null
		chroot /rootfs /sbin/veritysetup --version >/dev/null
		mkdir -p /export/sbin /export/usr
		cp -a /rootfs/sbin/veritysetup /export/sbin/
		cp -a /rootfs/lib /export/
		cp -a /rootfs/usr/lib /export/usr/
		chroot /rootfs /sbin/veritysetup --version \
			> /export/veritysetup-version
	'

echo "prepared $output_dir"
