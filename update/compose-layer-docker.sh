#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
manifest_tool=$repo_root/update/volatoo-manifest
platform=linux/amd64
portage_image=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8
compressor_image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}
state=
generation=current
build_context=
build_spec=
acquisition=
store=
output_dir=
declare -a repositories=()
repository_count=0

usage()
{
	cat <<'EOF'
Usage:
  update/compose-layer-docker.sh \
    --state DIRECTORY \
    [--generation current|previous|sha256:DIGEST] \
    --build-context FILE \
    --build-spec FILE \
    --acquisition FILE \
    --store DIRECTORY \
    --output-dir DIRECTORY \
    [--repository NAME=PATH] \
    [--portage-image IMAGE]

The published parent generation is reconstructed into a disposable Docker
volume. Portage runs inside that exact root. NAME=PATH repositories are
mounted read-only at /var/db/repos/NAME.
EOF
}

while (( $# > 0 )); do
	case $1 in
		--state)
			state=${2:?missing value for --state}
			shift 2
			;;
		--generation)
			generation=${2:?missing value for --generation}
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
		--store)
			store=${2:?missing value for --store}
			shift 2
			;;
		--output-dir)
			output_dir=${2:?missing value for --output-dir}
			shift 2
			;;
		--repository)
			repositories[repository_count]=${2:?missing value for --repository}
			((repository_count += 1))
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
	"$state" \
	"$build_context" \
	"$build_spec" \
	"$acquisition" \
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
	[[ -f $path && ! -L $path ]] || {
		echo "error: regular file not found: $path" >&2
		exit 1
	}
	(cd -- "$(dirname -- "$path")" && printf '%s/%s\n' "$PWD" "$(basename -- "$path")")
}

canonical_directory()
{
	local path=$1
	[[ -d $path && ! -L $path ]] || {
		echo "error: directory not found: $path" >&2
		exit 1
	}
	(cd -- "$path" && printf '%s\n' "$PWD")
}

build_context=$(canonical_file "$build_context")
build_spec=$(canonical_file "$build_spec")
acquisition=$(canonical_file "$acquisition")
state=$(canonical_directory "$state")
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
	portage-state.json \
	generation.json
do
	[[ ! -e $output_dir/$name ]] || {
		echo "error: output already exists: $output_dir/$name" >&2
		exit 1
	}
done

inspection=$("$generation_tool" inspect --state "$state" "$generation")
parent_digest=$(
	python3 -c \
		'import json,sys; print(json.load(sys.stdin)["generation_digest"])' \
		<<<"$inspection"
)
parent_plan_digest=$(
	python3 -c \
		'import json,sys; print(json.load(sys.stdin)["boot_plan_digest"])' \
		<<<"$inspection"
)
parent_generation=$state/volatoo/system/manifests/${parent_digest#sha256:}.json
parent_portage_state_digest=$(
	python3 -c \
		'import json,sys; print(json.load(sys.stdin).get("portage_state_digest") or "")' \
		<<<"$inspection"
)
verify_update_arguments=("$parent_generation" "$build_context")
if [[ -n $parent_portage_state_digest ]]; then
	verify_update_arguments+=(
		"$state/volatoo/system/objects/sha256/${parent_portage_state_digest#sha256:}"
	)
fi
"$manifest_tool" verify-update-context \
	"${verify_update_arguments[@]}" >/dev/null

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-layer-docker.XXXXXX")
repo_container=volatoo-layer-portage-$$
parent_volume=volatoo-layer-parent-$$-${RANDOM}
stage_volume=volatoo-layer-stage-$$-${RANDOM}

cleanup()
{
	docker rm -v "$repo_container" >/dev/null 2>&1 || true
	docker volume rm "$parent_volume" >/dev/null 2>&1 || true
	docker volume rm "$stage_volume" >/dev/null 2>&1 || true
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

mount_arguments=(--label org.volatoo.parent-root=verified)
repo_config=$work_dir/repos.conf
: >"$repo_config"
for ((index = 0; index < repository_count; index += 1)); do
	repository=${repositories[index]}
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
	[[ $name != gentoo ]] || {
		echo "error: the gentoo repository comes from --portage-image" >&2
		exit 2
	}
	path=$(canonical_directory "$path")
	mount_arguments+=(
		--mount
		"type=bind,src=$path,dst=/parent/root/var/db/repos/$name,readonly"
	)
	printf '[%s]\nlocation = /var/db/repos/%s\n\n' "$name" "$name" \
		>>"$repo_config"
done

docker build \
	--platform "$platform" \
	--tag "$compressor_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root"
docker create \
	--platform "$platform" \
	--name "$repo_container" \
	"$portage_image" >/dev/null
portage_volume=$(
	docker inspect \
		--format '{{range .Mounts}}{{if eq .Destination "/var/db/repos/gentoo"}}{{.Name}}{{end}}{{end}}' \
		"$repo_container"
)
[[ $portage_volume =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || {
	echo "error: --portage-image does not expose /var/db/repos/gentoo" >&2
	exit 1
}
docker volume create "$parent_volume" >/dev/null
docker volume create "$stage_volume" >/dev/null

docker run --rm \
	--platform "$platform" \
	--mount "type=bind,src=$state,dst=/state,readonly" \
	--mount "type=volume,src=$parent_volume,dst=/parent" \
	--entrypoint /usr/local/sbin/materialize-volatoo-generation \
	"$compressor_image" \
	/state \
	"$parent_digest" \
	"$parent_plan_digest" \
	/parent/root

docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$parent_volume,dst=/parent" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		mkdir -p \
			/parent/root/dev \
			/parent/root/inputs \
			/parent/root/output \
			/parent/root/proc \
			/parent/root/run \
			/parent/root/store \
			/parent/root/sys \
			/parent/root/tmp \
			/parent/root/var/db/repos/gentoo \
			/parent/root/work
	'

docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$parent_volume,dst=/parent" \
	--mount "type=volume,src=$stage_volume,dst=/parent/root/output" \
	--mount "type=volume,src=$portage_volume,dst=/parent/root/var/db/repos/gentoo,readonly" \
	--mount "type=bind,src=$repo_root,dst=/parent/root/work,readonly" \
	--mount "type=bind,src=$repo_config,dst=/parent/root/etc/portage/repos.conf/volatoo-layer.conf,readonly" \
	--mount "type=bind,src=$build_context,dst=/parent/root/inputs/build-context.json,readonly" \
	--mount "type=bind,src=$build_spec,dst=/parent/root/inputs/build-spec.json,readonly" \
	--mount "type=bind,src=$acquisition,dst=/parent/root/inputs/acquisition.json,readonly" \
	--mount "type=bind,src=$parent_generation,dst=/parent/root/inputs/parent-generation.json,readonly" \
	--mount "type=bind,src=$store,dst=/parent/root/store,readonly" \
	--mount "type=bind,src=/dev,dst=/parent/root/dev" \
	--mount "type=bind,src=/proc,dst=/parent/root/proc" \
	--mount "type=bind,src=/sys,dst=/parent/root/sys,readonly" \
	--tmpfs /parent/root/run:rw,exec,mode=755 \
	--tmpfs /parent/root/tmp:rw,exec,mode=1777 \
	"${mount_arguments[@]}" \
	--entrypoint /usr/sbin/chroot \
	"$compressor_image" \
	/parent/root \
	/usr/bin/python3 \
	/work/update/volatoo-layer stage \
		--build-context /inputs/build-context.json \
		--build-spec /inputs/build-spec.json \
		--acquisition /inputs/acquisition.json \
		--parent-generation /inputs/parent-generation.json \
		--store /store \
		--output-dir /output

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
	--portage-state "$output_dir/portage-state.json" \
	--generation "$output_dir/generation.json"
