#!/usr/bin/env bash

set -euo pipefail

if (( $# != 3 )); then
	echo "usage: $0 STAGE_IMAGE BUILD_CONTEXT OUTPUT_DIRECTORY" >&2
	exit 2
fi

stage_image=$1
context_source=$2
output_dir=$3
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
runtime_image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}
platform=linux/amd64

[[ -f $context_source && ! -L $context_source ]] || {
	echo "error: build context not found: $context_source" >&2
	exit 1
}
[[ ! -e $output_dir && ! -L $output_dir ]] || {
	echo "error: output already exists: $output_dir" >&2
	exit 1
}
mkdir -p "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
context_source=$(
	cd -- "$(dirname -- "$context_source")" &&
		printf '%s/%s\n' "$PWD" "$(basename -- "$context_source")"
)

root_volume=volatoo-stage-generation-root-$$-${RANDOM}
cleanup()
{
	docker volume rm "$root_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
	--platform "$platform" \
	--tag "$runtime_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root" >/dev/null
docker volume create "$root_volume" >/dev/null
docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$root_volume,dst=/snapshot" \
	--entrypoint /bin/bash \
	"$stage_image" \
	-c '
		set -euo pipefail
		tar -C / \
			--create --file=- \
			--numeric-owner --acls --xattrs \
			--one-file-system \
			--exclude=./snapshot \
			--exclude=./dev \
			--exclude=./proc \
			--exclude=./run \
			--exclude=./sys \
			--exclude=./tmp \
			--exclude=./var/db/repos \
			. |
			tar -C /snapshot \
				--extract --file=- \
				--numeric-owner --same-owner --same-permissions \
				--acls --xattrs
		mkdir -p \
			/snapshot/dev \
			/snapshot/proc \
			/snapshot/run \
			/snapshot/sys \
			/snapshot/tmp \
			/snapshot/var/db/repos
	'
docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$root_volume,dst=/input,readonly" \
	--mount "type=bind,src=$output_dir,dst=/output" \
	--entrypoint /usr/bin/mksquashfs \
	"$runtime_image" \
	/input \
	/output/base.squashfs \
		-noappend \
		-comp zstd \
		-Xcompression-level 1 \
		-b 1M \
		-all-time 0 \
		-mkfs-time 0 \
		-processors 4 \
		-no-progress >/dev/null

python3 "$fixture_tool" context \
	--build-context "$context_source" \
	--base "$output_dir/base.squashfs" \
	--output-dir "$output_dir/provenance"

state=$output_dir/state
mkdir -p \
	"$state/volatoo/config" \
	"$state/volatoo/data/bind" \
	"$state/volatoo/data/identity" \
	"$state/volatoo/data/overlay" \
	"$state/volatoo/data/sync" \
	"$state/volatoo/snapshots"
printf '1\n' >"$state/volatoo/layout-version"
"$generation_tool" migrate-state --state "$state" >/dev/null
"$generation_tool" publish \
	--state "$state" \
	--generation "$output_dir/provenance/base-generation.json" \
	--object "$output_dir/provenance/build-context.json" \
	--object "$output_dir/base.squashfs" \
	--activate \
	--expected-current none >/dev/null
