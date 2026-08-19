#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/require-docker-context.sh
source "$repo_root/scripts/require-docker-context.sh"
volatoo_require_docker_context

image=volatoo-live-iso-builder:0.1-dev
docker build --platform linux/amd64 --tag "$image" \
	--file "$repo_root/image/live-iso/Dockerfile" "$repo_root"
docker run --rm --network none --platform linux/amd64 \
	--entrypoint python3 \
	--mount "type=bind,src=$repo_root/image/live-iso/tests/test_normalize_iso.py,dst=/test-normalize-iso.py,readonly" \
	"$image" /test-normalize-iso.py /usr/local/sbin/normalize-volatoo-live-iso
