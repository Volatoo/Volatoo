#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-kernel-docker.sh OUTPUT

Build the pinned Volatoo amd64 kernel through the OrbStack Docker context.
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

if [[ $(docker context show) != orbstack ]]; then
	echo "error: Docker context must be orbstack" >&2
	exit 1
fi

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
