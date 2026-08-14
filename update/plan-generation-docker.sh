#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
manifest_tool=$repo_root/update/volatoo-manifest
platform=linux/amd64
portage_image=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8
runtime_image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}
state=
generation=current
build_context=
output=
query_output=
declare -a repositories=()
declare -a atoms=()
repository_count=0

usage()
{
	cat <<'EOF'
Usage:
  update/plan-generation-docker.sh \
    --state DIRECTORY \
    --generation current|previous|sha256:DIGEST \
    --build-context FILE \
    --output FILE \
    --query-output FILE \
    [--repository NAME=PATH] \
    [--portage-image IMAGE] \
    ATOM...

Reconstruct the verified parent generation and run Portage inside that exact
root. Repository snapshots are mounted read-only for resolution.
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
		--output)
			output=${2:?missing value for --output}
			shift 2
			;;
		--query-output)
			query_output=${2:?missing value for --query-output}
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
		--)
			shift
			atoms+=("$@")
			break
			;;
		-*)
			echo "error: unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			atoms+=("$1")
			shift
			;;
	esac
done

for value in "$state" "$build_context" "$output" "$query_output"; do
	[[ -n $value ]] || {
		echo "error: all required arguments must be provided" >&2
		exit 2
	}
done
(( ${#atoms[@]} > 0 )) || {
	echo "error: at least one package atom is required" >&2
	exit 2
}
[[ $output != "$query_output" ]] || {
	echo "error: --output and --query-output must differ" >&2
	exit 2
}

canonical_file()
{
	local path=$1
	[[ -f $path && ! -L $path ]] || {
		echo "error: regular file not found: $path" >&2
		exit 1
	}
	(cd -- "$(dirname -- "$path")" &&
		printf '%s/%s\n' "$PWD" "$(basename -- "$path")")
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

state=$(canonical_directory "$state")
build_context=$(canonical_file "$build_context")
for path in "$output" "$query_output"; do
	[[ ! -e $path && ! -L $path ]] || {
		echo "error: output already exists: $path" >&2
		exit 1
	}
	mkdir -p "$(dirname -- "$path")"
done
output=$(cd -- "$(dirname -- "$output")" &&
	printf '%s/%s\n' "$PWD" "$(basename -- "$output")")
query_output=$(cd -- "$(dirname -- "$query_output")" &&
	printf '%s/%s\n' "$PWD" "$(basename -- "$query_output")")

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
parent_manifest=$state/volatoo/system/manifests/${parent_digest#sha256:}.json
parent_portage_state_digest=$(
	python3 -c \
		'import json,sys; print(json.load(sys.stdin).get("portage_state_digest") or "")' \
		<<<"$inspection"
)
verify_update_arguments=("$parent_manifest" "$build_context")
if [[ -n $parent_portage_state_digest ]]; then
	verify_update_arguments+=(
		"$state/volatoo/system/objects/sha256/${parent_portage_state_digest#sha256:}"
	)
fi
"$manifest_tool" verify-update-context \
	"${verify_update_arguments[@]}" >/dev/null

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-plan-generation.XXXXXX")
repo_container=volatoo-plan-generation-portage-$$
parent_volume=volatoo-plan-generation-parent-$$-${RANDOM}

cleanup()
{
	docker rm -v "$repo_container" >/dev/null 2>&1 || true
	docker volume rm "$parent_volume" >/dev/null 2>&1 || true
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

repo_config=$work_dir/repos.conf
: >"$repo_config"
mount_arguments=(--label org.volatoo.parent-root=verified)
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
	--tag "$runtime_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root" >/dev/null
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

docker run --rm \
	--platform "$platform" \
	--mount "type=bind,src=$state,dst=/state,readonly" \
	--mount "type=volume,src=$parent_volume,dst=/parent" \
	--entrypoint /usr/local/sbin/materialize-volatoo-generation \
	"$runtime_image" \
	/state \
	"$parent_digest" \
	"$parent_plan_digest" \
	/parent/root

docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$parent_volume,dst=/parent" \
	--entrypoint /bin/sh \
	"$runtime_image" \
	-c '
		set -eu
		mkdir -p \
			/parent/root/dev \
			/parent/root/inputs \
			/parent/root/proc \
			/parent/root/result \
			/parent/root/run \
			/parent/root/sys \
			/parent/root/tmp \
			/parent/root/var/db/repos/gentoo \
			/parent/root/work
	'

docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$parent_volume,dst=/parent" \
	--mount "type=volume,src=$portage_volume,dst=/parent/root/var/db/repos/gentoo,readonly" \
	--mount "type=bind,src=$repo_root,dst=/parent/root/work,readonly" \
	--mount "type=bind,src=$work_dir,dst=/parent/root/result" \
	--mount "type=bind,src=$build_context,dst=/parent/root/inputs/build-context.json,readonly" \
	--mount "type=bind,src=$repo_config,dst=/parent/root/etc/portage/repos.conf/volatoo-generation.conf,readonly" \
	--mount "type=bind,src=/dev,dst=/parent/root/dev" \
	--mount "type=bind,src=/proc,dst=/parent/root/proc" \
	--mount "type=bind,src=/sys,dst=/parent/root/sys,readonly" \
	--tmpfs /parent/root/run:rw,exec,mode=755 \
	--tmpfs /parent/root/tmp:rw,exec,mode=1777 \
	"${mount_arguments[@]}" \
	--entrypoint /usr/sbin/chroot \
	"$runtime_image" \
	/parent/root \
	/usr/bin/python3 \
	/work/update/volatoo-plan \
		--build-context /inputs/build-context.json \
		--output /result/build-spec.json \
		--query-output /result/query.json \
		"${atoms[@]}"

install -m 0644 "$work_dir/build-spec.json" "$output"
install -m 0644 "$work_dir/query.json" "$query_output"
