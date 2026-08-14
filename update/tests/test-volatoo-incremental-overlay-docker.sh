#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
platform=linux/amd64
image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}

command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

docker build \
	--platform "$platform" \
	--tag "$image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root"

docker run --rm \
	--privileged \
	--network none \
	--platform "$platform" \
	--tmpfs /case:exec,dev,suid,size=64m \
	--entrypoint /bin/sh \
	"$image" \
	-c '
		set -eu

		mkdir -p \
			/case/base/replaced-directory \
			/case/top/replaced-directory \
			/case/merged \
			/case/upper \
			/case/work
		printf old >/case/base/replaced-directory/old-child
		printf deleted >/case/base/deleted-path
		printf new >/case/top/replaced-directory/new-child

		setfattr \
			-n trusted.overlay.opaque \
			-v y \
			/case/top/replaced-directory
		mknod /case/top/deleted-path c 0 0
		chmod 000 /case/top/deleted-path

		mksquashfs /case/top /case/top.squashfs \
			-noappend \
			-comp zstd \
			-Xcompression-level 19 \
			-b 1M \
			-all-time 0 \
			-mkfs-time 0 \
			-reproducible \
			-processors 1 \
			-no-progress >/dev/null
		unsquashfs \
			-no-progress \
			-d /case/restored-top \
			/case/top.squashfs >/dev/null

		test "$(
			getfattr \
				--only-values \
				-n trusted.overlay.opaque \
				/case/restored-top/replaced-directory
		)" = y
		test -c /case/restored-top/deleted-path
		test "$(stat -c "%t:%T" /case/restored-top/deleted-path)" = 0:0

		mount -t overlay overlay \
			-o lowerdir=/case/restored-top:/case/base,upperdir=/case/upper,workdir=/case/work \
			/case/merged
		test -f /case/merged/replaced-directory/new-child
		test ! -e /case/merged/replaced-directory/old-child
		test ! -e /case/merged/deleted-path
	'

echo "incremental OverlayFS semantics test passed"
