#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage:
  update/tests/corrupt-state-signature-docker.sh \
    STATE_IMAGE REALIZATION_DIGEST KEY_DIGEST

Flip the first byte of one detached realization signature inside a fixture
ext4 image. This is test-only tooling and never discovers a target device.
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi
if (( $# != 3 )); then
	usage >&2
	exit 2
fi

state_image=$1
realization_digest=$2
key_digest=$3
if [[ ! -f $state_image || -L $state_image ]]; then
	echo "error: state image is missing or unsafe: $state_image" >&2
	exit 1
fi
for digest in "$realization_digest" "$key_digest"; do
	if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "error: digest must be sha256:<64 lowercase hex digits>" >&2
		exit 2
	fi
done
command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

state_image=$(cd -- "$(dirname -- "$state_image")" && pwd)/$(basename -- "$state_image")
signature_path=/volatoo/system/signatures/${realization_digest#sha256:}/${key_digest#sha256:}.sig
docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$state_image,dst=/state.ext4" \
	--entrypoint /bin/sh \
	amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f \
	-c '
		set -eu
		apk add --no-cache e2fsprogs-extra >/dev/null
		block=$(
			debugfs -R "bmap '"$signature_path"' 0" /state.ext4 \
				2>/dev/null
		)
		case $block in
			"" | *[!0-9]*)
				echo "error: could not resolve signature block" >&2
				exit 1
				;;
		esac
		block_size=$(
			debugfs -R stats /state.ext4 2>/dev/null |
				awk "/^Block size:/ { print \$3; exit }"
		)
		case $block_size in
			"" | *[!0-9]*)
				echo "error: could not resolve ext4 block size" >&2
				exit 1
				;;
		esac
		offset=$((block * block_size))
		printf X |
			dd of=/state.ext4 bs=1 seek="$offset" \
				count=1 conv=notrunc 2>/dev/null
	'

echo "corrupted signature for $realization_digest from $key_digest"
