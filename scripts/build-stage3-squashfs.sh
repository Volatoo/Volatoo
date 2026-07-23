#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-stage3-squashfs.sh [OUTPUT]

Build an amd64 OpenRC Gentoo stage3 squashfs with Docker Buildx. OUTPUT
defaults to out/volatoo-stage3.squashfs.

Optional environment variables:
  VOLATOO_GENTOO_IMAGE  Stage3 OCI image (default: gentoo/stage3:latest)
  VOLATOO_ZSTD_LEVEL    Squashfs Zstd level, 1-22 (default: 19)
  VOLATOO_BUILD_NONCE   Cache key for forced measurement rebuilds
EOF
}

if (( $# > 1 )); then
	usage >&2
	exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_path=${1:-"$repo_root/out/volatoo-stage3.squashfs"}
gentoo_image=${VOLATOO_GENTOO_IMAGE:-gentoo/stage3:latest}
zstd_level=${VOLATOO_ZSTD_LEVEL:-19}
build_nonce=${VOLATOO_BUILD_NONCE:-default}

if ! [[ $zstd_level =~ ^([1-9]|1[0-9]|2[0-2])$ ]]; then
	echo "error: VOLATOO_ZSTD_LEVEL must be an integer from 1 to 22" >&2
	exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "error: docker is not installed" >&2
	exit 1
fi

if ! docker info >/dev/null 2>&1; then
	echo "error: the Docker daemon is not available" >&2
	exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
	checksum_command=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
	checksum_command=(shasum -a 256)
else
	echo "error: sha256sum or shasum is required" >&2
	exit 1
fi

mkdir -p "$(dirname -- "$output_path")"
output_path=$(cd -- "$(dirname -- "$output_path")" && pwd)/$(basename -- "$output_path")

export_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-stage3.XXXXXX")
cleanup() {
	rm -rf -- "$export_dir"
}
trap cleanup EXIT

docker buildx build \
	--platform linux/amd64 \
	--progress plain \
	--build-arg "GENTOO_IMAGE=$gentoo_image" \
	--build-arg "ZSTD_LEVEL=$zstd_level" \
	--build-arg "BUILD_NONCE=$build_nonce" \
	--output "type=local,dest=$export_dir" \
	--file "$repo_root/image/prototype/Dockerfile" \
	"$repo_root"

mv -- "$export_dir/volatoo-stage3.squashfs" "$output_path"
checksum_output=$("${checksum_command[@]}" "$output_path")
checksum=${checksum_output%% *}
printf '%s  %s\n' "$checksum" "$(basename -- "$output_path")" \
	> "$output_path.sha256"
echo "built $output_path"
echo "wrote $output_path.sha256"
