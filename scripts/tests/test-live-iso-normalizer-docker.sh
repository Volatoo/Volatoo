#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

image=volatoo-live-iso-builder:0.1-dev
docker build --platform linux/amd64 --tag "$image" \
	--file "$repo_root/image/live-iso/Dockerfile" "$repo_root"
docker run --rm --network none --platform linux/amd64 \
	--entrypoint python3 \
	--mount "type=bind,src=$repo_root/image/live-iso/tests/test_normalize_iso.py,dst=/test-normalize-iso.py,readonly" \
	"$image" /test-normalize-iso.py /usr/local/sbin/normalize-volatoo-live-iso
