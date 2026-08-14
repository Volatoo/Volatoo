#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
platform=linux/amd64
compressor_image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}
state=
generation=current
output_dir=
minimum_layers=4
activate=no
force=no

usage()
{
	cat <<'EOF'
Usage:
  update/compact-generation-docker.sh \
    --state DIRECTORY \
    --output-dir DIRECTORY \
    [--generation current|previous|sha256:DIGEST] \
    [--minimum-layers NUMBER] \
    [--activate] \
    [--force]

Reconstruct a verified generation inside Docker, recompress it as one base,
verify filesystem equivalence, publish the compacted generation and optionally
select it. Compaction never reads the mutable live root.
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
		--minimum-layers)
			minimum_layers=${2:?missing value for --minimum-layers}
			shift 2
			;;
		--activate)
			activate=yes
			shift
			;;
		--force)
			force=yes
			shift
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
[[ $minimum_layers =~ ^[1-9][0-9]*$ ]] || {
	echo "error: --minimum-layers must be a positive integer" >&2
	exit 2
}
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
for name in \
	base.squashfs \
	build-context.json \
	generation.json \
	compaction.json \
	fhs-contract \
	tree-digest
do
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
expected_current=none
if [[ -e $state/volatoo/system/current ||
	-L $state/volatoo/system/current ]]; then
	current_inspection=$(
		"$generation_tool" inspect --state "$state" current
	)
	expected_current=$(
		python3 -c \
			'import json,sys; print(json.load(sys.stdin)["generation_digest"])' \
			<<<"$current_inspection"
	)
fi
layer_count=$(
	python3 -c 'import json,sys; print(json.load(sys.stdin)["layer_count"])' \
		<<<"$inspection"
)
if [[ $force != yes && $layer_count -lt $minimum_layers ]]; then
	echo "error: generation has $layer_count layers; threshold is $minimum_layers" >&2
	exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-compact.XXXXXX")
workspace_volume=volatoo-compact-$$-${RANDOM}
cleanup()
{
	docker volume rm "$workspace_volume" >/dev/null 2>&1 || true
	find "$work_dir" -depth -delete 2>/dev/null || true
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
	--mount "type=bind,src=$state,dst=/state,readonly" \
	--mount "type=volume,src=$workspace_volume,dst=/workspace" \
	--entrypoint /usr/local/sbin/compact-volatoo-generation \
	"$compressor_image" \
	/state \
	"$resolved_generation" \
	"$boot_plan_digest" \
	/workspace \
	"$target_id"
docker run --rm \
	--platform "$platform" \
	--mount "type=volume,src=$workspace_volume,dst=/workspace,readonly" \
	--mount "type=bind,src=$output_dir,dst=/export" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		cp /workspace/base.squashfs /export/base.squashfs
		cp /workspace/fhs-contract /export/fhs-contract
		cp /workspace/tree-digest /export/tree-digest
		cmp /workspace/tree-digest /workspace/verified-tree-digest
	'

tree_digest=sha256:$(tr -d '[:space:]' <"$output_dir/tree-digest")
"$generation_tool" compact-manifest \
	--state "$state" \
	--generation "$resolved_generation" \
	--base "$output_dir/base.squashfs" \
	--context-output "$output_dir/build-context.json" \
	--output "$output_dir/generation.json" \
	--receipt "$output_dir/compaction.json" \
	--tree-digest "$tree_digest"
"$generation_tool" publish \
	--state "$state" \
	--generation "$output_dir/generation.json" \
	--object "$output_dir/build-context.json" \
	--object "$output_dir/base.squashfs"
"$generation_tool" record-compaction \
	--state "$state" \
	--receipt "$output_dir/compaction.json"

if [[ $activate == yes ]]; then
	compacted_digest=$(
		"$repo_root/update/volatoo-manifest" \
			digest "$output_dir/generation.json"
	)
	"$generation_tool" select \
		--state "$state" \
		--expected-current "$expected_current" \
		"$compacted_digest"
fi

echo "compacted $resolved_generation from $layer_count layers"
