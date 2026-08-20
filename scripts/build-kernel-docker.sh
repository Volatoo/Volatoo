#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-kernel-docker.sh OUTPUT

Build the pinned Volatoo amd64 kernel through Docker. Local builds require the
OrbStack context; GitHub Actions Linux uses its default hosted Docker daemon.
Kernel sources and intermediate objects are retained in a named Docker volume.
OUTPUT must not already exist.
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

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_path=$1
if [[ -e $output_path || -L $output_path ]]; then
	echo "error: output already exists: $output_path" >&2
	exit 1
fi
mkdir -p "$(dirname -- "$output_path")"
output_directory=$(cd -- "$(dirname -- "$output_path")" && pwd)
output_name=$(basename -- "$output_path")
if ! [[ $output_name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
	echo "error: output basename contains unsupported characters" >&2
	exit 2
fi

# The guard is checked separately; its path is rooted dynamically for macOS.
# shellcheck disable=SC1091
source "$repo_root/scripts/require-docker-context.sh"
volatoo_require_docker_context

docker build \
	--tag volatoo-kernel-builder:6.18.40 \
	--file "$repo_root/scripts/kernel-container/Dockerfile" \
	"$repo_root"

docker volume create volatoo-kernel-6.18.40 >/dev/null
docker run --rm \
	--mount "type=bind,src=$repo_root,dst=/repo,readonly" \
	--mount "type=bind,src=$output_directory,dst=/output" \
	--mount type=volume,src=volatoo-kernel-6.18.40,dst=/work \
	--env "VOLATOO_BUILD_JOBS=${VOLATOO_BUILD_JOBS:-}" \
	volatoo-kernel-builder:6.18.40 \
	"$output_name"
