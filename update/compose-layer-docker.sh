#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
platform=linux/amd64
portage_image=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8
compressor_image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}
stage_image=
build_context=
build_spec=
acquisition=
parent_generation=
store=
output_dir=
declare -a repositories=()

usage()
{
	cat <<'EOF'
Usage:
  update/compose-layer-docker.sh \
    --stage-image IMAGE \
    --build-context FILE \
    --build-spec FILE \
    --acquisition FILE \
    --parent-generation FILE \
    --store DIRECTORY \
    --output-dir DIRECTORY \
    [--repository NAME=PATH] \
    [--portage-image IMAGE]

The selected stage image is mutated only inside a disposable Docker container.
NAME=PATH repositories are mounted read-only at /var/db/repos/NAME.
EOF
}

while (( $# > 0 )); do
	case $1 in
		--stage-image)
			stage_image=${2:?missing value for --stage-image}
			shift 2
			;;
		--build-context)
			build_context=${2:?missing value for --build-context}
			shift 2
			;;
		--build-spec)
			build_spec=${2:?missing value for --build-spec}
			shift 2
			;;
		--acquisition)
			acquisition=${2:?missing value for --acquisition}
			shift 2
			;;
		--parent-generation)
			parent_generation=${2:?missing value for --parent-generation}
			shift 2
			;;
		--store)
			store=${2:?missing value for --store}
			shift 2
			;;
		--output-dir)
			output_dir=${2:?missing value for --output-dir}
			shift 2
			;;
		--repository)
			repositories+=("${2:?missing value for --repository}")
			shift 2
			;;
		--portage-image)
			portage_image=${2:?missing value for --portage-image}
			shift 2
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "error: unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

for value in \
	"$stage_image" \
	"$build_context" \
	"$build_spec" \
	"$acquisition" \
	"$parent_generation" \
	"$store" \
	"$output_dir"
do
	[[ -n $value ]] || {
		echo "error: all required arguments must be provided" >&2
		exit 2
	}
done

canonical_file()
{
	local path=$1
	[[ -f $path ]] || {
		echo "error: file not found: $path" >&2
		exit 1
	}
	(cd -- "$(dirname -- "$path")" && printf '%s/%s\n' "$PWD" "$(basename -- "$path")")
}

canonical_directory()
{
	local path=$1
	[[ -d $path ]] || {
		echo "error: directory not found: $path" >&2
		exit 1
	}
	(cd -- "$path" && printf '%s\n' "$PWD")
}

build_context=$(canonical_file "$build_context")
build_spec=$(canonical_file "$build_spec")
acquisition=$(canonical_file "$acquisition")
parent_generation=$(canonical_file "$parent_generation")
store=$(canonical_directory "$store")
mkdir -p "$output_dir"
output_dir=$(canonical_directory "$output_dir")

for name in \
	changed-paths.json \
	tombstones.json \
	stage-report.json \
	compressor-version \
	layer.squashfs \
	transaction.json \
	generation.json
do
	[[ ! -e $output_dir/$name ]] || {
		echo "error: output already exists: $output_dir/$name" >&2
		exit 1
	}
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-layer-docker.XXXXXX")
repo_container=volatoo-layer-portage-$$
stage_volume=volatoo-layer-stage-$$-${RANDOM}

cleanup()
{
	docker rm "$repo_container" >/dev/null 2>&1 || true
	docker volume rm "$stage_volume" >/dev/null 2>&1 || true
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

mount_arguments=()
repo_config=$work_dir/repos.conf
: >"$repo_config"
for repository in "${repositories[@]}"; do
	[[ $repository == *=* ]] || {
		echo "error: repository must use NAME=PATH: $repository" >&2
		exit 2
	}
	name=${repository%%=*}
	path=${repository#*=}
	[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
		echo "error: invalid repository name: $name" >&2
		exit 2
	}
	path=$(canonical_directory "$path")
	mount_arguments+=(
		--mount
		"type=bind,src=$path,dst=/var/db/repos/$name,readonly"
	)
	printf '[%s]\nlocation = /var/db/repos/%s\n\n' "$name" "$name" \
		>>"$repo_config"
done

docker create \
	--platform "$platform" \
	--name "$repo_container" \
	"$portage_image" >/dev/null
docker volume create "$stage_volume" >/dev/null

docker run --rm \
	--platform "$platform" \
	--volumes-from "$repo_container" \
	"${mount_arguments[@]}" \
	--mount "type=bind,src=$repo_root,dst=/work,readonly" \
	--mount "type=bind,src=$repo_config,dst=/etc/portage/repos.conf/volatoo-layer.conf,readonly" \
	--mount "type=bind,src=$build_context,dst=/inputs/build-context.json,readonly" \
	--mount "type=bind,src=$build_spec,dst=/inputs/build-spec.json,readonly" \
	--mount "type=bind,src=$acquisition,dst=/inputs/acquisition.json,readonly" \
	--mount "type=bind,src=$parent_generation,dst=/inputs/parent-generation.json,readonly" \
	--mount "type=bind,src=$store,dst=/store,readonly" \
	--mount "type=volume,src=$stage_volume,dst=/output" \
	--entrypoint /usr/bin/python3 \
	"$stage_image" \
	/work/update/volatoo-layer stage \
		--build-context /inputs/build-context.json \
		--build-spec /inputs/build-spec.json \
		--acquisition /inputs/acquisition.json \
		--parent-generation /inputs/parent-generation.json \
		--store /store \
		--output-dir /output

docker build \
	--platform "$platform" \
	--tag "$compressor_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root"

docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$stage_volume,dst=/workspace" \
	"$compressor_image" \
	/workspace/layer-root \
	/workspace

docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$stage_volume,dst=/workspace,readonly" \
	--mount "type=bind,src=$output_dir,dst=/export" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		for name in \
			changed-paths.json \
			tombstones.json \
			stage-report.json \
			compressor-version \
			layer.squashfs
		do
			cp "/workspace/$name" "/export/$name"
		done
	'

"$repo_root/update/volatoo-layer" finalize \
	--build-context "$build_context" \
	--build-spec "$build_spec" \
	--acquisition "$acquisition" \
	--parent-generation "$parent_generation" \
	--changed-paths "$output_dir/changed-paths.json" \
	--tombstones "$output_dir/tombstones.json" \
	--stage-report "$output_dir/stage-report.json" \
	--squashfs "$output_dir/layer.squashfs" \
	--compressor-version "$output_dir/compressor-version" \
	--transaction "$output_dir/transaction.json" \
	--generation "$output_dir/generation.json"
