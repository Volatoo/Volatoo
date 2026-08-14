#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

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
	--mount "type=bind,src=$repo_root,dst=/workspace,readonly" \
	--workdir /workspace \
	amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f \
	sh -c '
		set -eu
		apk add --no-cache \
			bash \
			coreutils \
			jq \
			python3 \
			signify=32-r1 >/dev/null
		update/tests/test-volatoo-generation.sh
		update/tests/test-volatoo-incremental-realization.sh
	'

echo "Volatoo realization signature tests passed"
