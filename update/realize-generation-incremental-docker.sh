#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
platform=linux/amd64
compressor_image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}
state=
generation=current
output_dir=
activate=no
expected_current=
signing_key=
trusted_key=

usage()
{
	cat <<'EOF'
Usage:
  update/realize-generation-incremental-docker.sh \
    --state DIRECTORY \
    --output-dir DIRECTORY \
    [--generation current|previous|sha256:DIGEST] \
    [--signing-key KEY.sec --trusted-key KEY.pub] \
    [--activate --expected-current DIGEST|none]

Validate the final Gentoo/FHS state, convert only layers with deletions to
OverlayFS-whiteout SquashFS images, create an independent dm-verity tree for
the base and every layer, and publish a signed realization-v3 plan. An exact
indexed direct child scans only its new layer and validates the merged
authenticated index. Set VOLATOO_VALIDATION_AUDIT=1 to additionally scan the
complete tree and require byte-identical indexes.

An exact direct-parent realization-v3 record is reused for unchanged images.
The complete closure is not recompressed. Full closure reconstruction remains
the compaction and release-image path.
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
		--output-dir)
			output_dir=${2:?missing value for --output-dir}
			shift 2
			;;
		--activate)
			activate=yes
			shift
			;;
		--expected-current)
			expected_current=${2:?missing value for --expected-current}
			shift 2
			;;
		--signing-key)
			signing_key=${2:?missing value for --signing-key}
			shift 2
			;;
		--trusted-key)
			trusted_key=${2:?missing value for --trusted-key}
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

[[ -n $state && -n $output_dir ]] || {
	echo "error: --state and --output-dir are required" >&2
	exit 2
}
if [[ $activate == yes && -z $expected_current ]]; then
	echo "error: --activate requires --expected-current DIGEST|none" >&2
	exit 2
fi
if [[ $activate == no && -n $expected_current ]]; then
	echo "error: --expected-current requires --activate" >&2
	exit 2
fi
if [[ -n $signing_key || -n $trusted_key ]]; then
	[[ -n $signing_key && -n $trusted_key ]] || {
		echo "error: --signing-key and --trusted-key are required together" >&2
		exit 2
	}
	for key_path in "$signing_key" "$trusted_key"; do
		[[ -f $key_path && ! -L $key_path ]] || {
			echo "error: signing key is missing or unsafe: $key_path" >&2
			exit 1
		}
	done
	signing_key=$(cd -- "$(dirname -- "$signing_key")" && pwd)/$(basename -- "$signing_key")
	trusted_key=$(cd -- "$(dirname -- "$trusted_key")" && pwd)/$(basename -- "$trusted_key")
fi
if [[ -n $expected_current && \
	$expected_current != none && \
	! $expected_current =~ ^sha256:[0-9a-f]{64}$ ]]; then
	echo "error: --expected-current must be a SHA-256 digest or none" >&2
	exit 2
fi
command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}
[[ -d $state ]] || {
	echo "error: state directory not found: $state" >&2
	exit 1
}
state=$(cd -- "$state" && pwd)
mkdir -p "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
for name in realization.plan objects fhs-contract tree-digest parent-tree.receipt validation-index tree-state reuse-report; do
	[[ ! -e $output_dir/$name ]] || {
		echo "error: output already exists: $output_dir/$name" >&2
		exit 1
	}
done

inspection=$("$generation_tool" inspect --state "$state" "$generation")
resolved_generation=$(
	python3 -c 'import json,sys; print(json.load(sys.stdin)["generation_digest"])' \
		<<<"$inspection"
)
boot_plan_digest=$(
	python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_plan_digest"])' \
		<<<"$inspection"
)
target_id=$(
	python3 -c 'import json,sys; print(json.load(sys.stdin)["target_id"])' \
		<<<"$inspection"
)
layer_count=$(
	python3 -c 'import json,sys; print(json.load(sys.stdin)["layer_count"])' \
		<<<"$inspection"
)
parent_generation=$(
	python3 -c 'import json,sys; print(json.load(sys.stdin).get("parent_generation_digest") or "")' \
		<<<"$inspection"
)
if (( layer_count > 64 )); then
	echo "error: incremental realization supports at most 64 layers; compact first" >&2
	exit 1
fi

reuse_realization=none
parent_argument=none
if [[ -n $parent_generation ]]; then
	parent_argument=$parent_generation
	parent_inspection=$(
		"$generation_tool" inspect --state "$state" "$parent_generation"
	)
	reuse_realization=$(
		python3 -c '
import json
import sys

realization = json.load(sys.stdin).get("realization")
if realization is not None and realization.get("contract_version") == 3:
    print(realization["realization_digest"])
else:
    print("none")
' <<<"$parent_inspection"
	)
fi

workspace_volume=volatoo-incremental-realize-$$-${RANDOM}
cleanup()
{
	docker volume rm "$workspace_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
	--platform "$platform" \
	--tag "$compressor_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root"
docker volume create "$workspace_volume" >/dev/null
docker run --rm \
	--platform "$platform" \
	--env "VOLATOO_VALIDATION_AUDIT=${VOLATOO_VALIDATION_AUDIT:-0}" \
	--mount "type=bind,src=$state,dst=/state,readonly" \
	--mount "type=volume,src=$workspace_volume,dst=/workspace" \
	--entrypoint /usr/local/sbin/prepare-volatoo-incremental-realization \
	"$compressor_image" \
	/state \
	"$resolved_generation" \
	"$boot_plan_digest" \
	/workspace \
	"$target_id" \
	"$reuse_realization" \
	"$parent_argument"
docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$workspace_volume,dst=/workspace,readonly" \
	--mount "type=bind,src=$output_dir,dst=/export" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		mkdir /export/objects
		cp /workspace/realization.plan /export/realization.plan
		cp /workspace/fhs-contract /export/fhs-contract
		cp /workspace/tree-digest /export/tree-digest
		cp /workspace/parent-tree.receipt /export/parent-tree.receipt
		cp /workspace/validation.index /export/validation-index
		cp /workspace/tree.state /export/tree-state
		cp /workspace/reuse-report /export/reuse-report
		for object in /workspace/publish/*; do
			[ -f "$object" ] || continue
			cp "$object" /export/objects/
		done
	'

record_arguments=(
	record-incremental-realization
	--state "$state"
	--generation "$resolved_generation"
	--plan "$output_dir/realization.plan"
)
for object in "$output_dir"/objects/*; do
	[[ -f $object ]] || continue
	record_arguments+=(--object "$object")
done
if [[ $activate == yes && -z $signing_key ]]; then
	record_arguments+=(
		--activate
		--expected-current "$expected_current"
	)
fi
"$generation_tool" "${record_arguments[@]}"

if [[ -n $signing_key ]]; then
	sign_arguments=(
		/repo/update/volatoo-generation
		sign-realization
		--state /state
		--generation "$resolved_generation"
		--secret-key /run/volatoo-signing/release.sec
		--trusted-key /run/volatoo-signing/release.pub
		--signify /usr/bin/signify
	)
	if [[ $activate == yes ]]; then
		sign_arguments+=(
			--activate
			--expected-current "$expected_current"
		)
	fi
	docker run --rm \
		--platform "$platform" \
		--network none \
		--mount "type=bind,src=$repo_root,dst=/repo,readonly" \
		--mount "type=bind,src=$state,dst=/state" \
		--mount "type=bind,src=$signing_key,dst=/run/volatoo-signing/release.sec,readonly" \
		--mount "type=bind,src=$trusted_key,dst=/run/volatoo-signing/release.pub,readonly" \
		--entrypoint /usr/bin/python3 \
		"$compressor_image" \
		"${sign_arguments[@]}"
fi

echo "incrementally realized generation $resolved_generation"
