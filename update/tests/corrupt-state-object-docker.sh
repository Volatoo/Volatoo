#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: update/tests/corrupt-state-object-docker.sh STATE_IMAGE SHA256_DIGEST

Flip the first byte of one content-addressed object inside a fixture ext4
image. This is test-only tooling and never discovers a target device.
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi
if (( $# != 2 )); then
	usage >&2
	exit 2
fi

state_image=$1
digest=$2
if [[ ! -f $state_image || -L $state_image ]]; then
	echo "error: state image is missing or unsafe: $state_image" >&2
	exit 1
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
	echo "error: object digest must be sha256:<64 lowercase hex digits>" >&2
	exit 2
fi
command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

state_image=$(cd -- "$(dirname -- "$state_image")" && pwd)/$(basename -- "$state_image")
object_path=/volatoo/system/objects/sha256/${digest#sha256:}
docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$state_image,dst=/state.ext4" \
	--entrypoint /bin/sh \
	alpine:3.24.1 \
	-c '
		set -eu
		apk add --no-cache e2fsprogs-extra >/dev/null
		block=$(
			debugfs -R "bmap '"$object_path"' 0" /state.ext4 \
				2>/dev/null
		)
		case $block in
			"" | *[!0-9]*)
				echo "error: could not resolve object block" >&2
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

echo "corrupted $digest in $state_image"
