#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
manifest=$repo_root/update/volatoo-manifest
compressor_image=volatoo-layer-compressor:compaction-test
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-compaction-test.XXXXXX")

cleanup()
{
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

raw_digest()
{
	if command -v sha256sum >/dev/null 2>&1; then
		checksum_output=$(sha256sum "$1")
	else
		checksum_output=$(shasum -a 256 "$1")
	fi
	printf 'sha256:%s\n' "${checksum_output%% *}"
}

canonical_digest()
{
	"$manifest" digest "$1"
}

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

state=$work_dir/state
system=$state/volatoo/system
mkdir -p \
	"$state/volatoo/config" \
	"$state/volatoo/data/bind" \
	"$state/volatoo/data/identity" \
	"$state/volatoo/data/overlay" \
	"$state/volatoo/data/sync" \
	"$state/volatoo/snapshots" \
	"$work_dir/base-root/etc" \
	"$work_dir/layer-1/etc" \
	"$work_dir/layer-2/etc" \
	"$work_dir/base-output" \
	"$work_dir/layer-output-1" \
	"$work_dir/layer-output-2"
printf '1\n' >"$state/volatoo/layout-version"
"$generation_tool" migrate-state --state "$state" >/dev/null

printf 'base\n' >"$work_dir/base-root/etc/base"
printf 'remove-me\n' >"$work_dir/base-root/etc/removed"
printf 'old\n' >"$work_dir/base-root/etc/replaced"
printf 'layer-one\n' >"$work_dir/layer-1/etc/layer-one"
printf 'v1\n' >"$work_dir/layer-1/etc/replaced"
printf 'layer-two\n' >"$work_dir/layer-2/etc/layer-two"
printf 'v2\n' >"$work_dir/layer-2/etc/replaced"

docker build \
	--platform linux/amd64 \
	--tag "$compressor_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root" >/dev/null
for entry in \
	base:"$work_dir/base-root":"$work_dir/base-output" \
	1:"$work_dir/layer-1":"$work_dir/layer-output-1" \
	2:"$work_dir/layer-2":"$work_dir/layer-output-2"
do
	input=${entry#*:}
	input=${input%%:*}
	output=${entry##*:}
	docker run --rm \
		--platform linux/amd64 \
		--mount "type=bind,src=$input,dst=/input,readonly" \
		--mount "type=bind,src=$output,dst=/output" \
		"$compressor_image" >/dev/null
done
mv "$work_dir/base-output/layer.squashfs" \
	"$work_dir/base-output/base.squashfs"

"$manifest" canonicalize \
	"$repo_root/update/examples/build-context-v1.json" \
	>"$work_dir/context.json"
target_id=$(jq -r '.target.id' "$work_dir/context.json")
context_digest=$(canonical_digest "$work_dir/context.json")
base=$work_dir/base-output/base.squashfs
base_digest=$(raw_digest "$base")
base_size=$(wc -c <"$base" | tr -d ' ')

declare -a layer_digests=()
declare -a layer_sizes=()
declare -a tombstone_digests=()
declare -a transaction_digests=()
for number in 1 2; do
	layer=$work_dir/layer-output-$number/layer.squashfs
	layer_digests[number]=$(raw_digest "$layer")
	layer_sizes[number]=$(wc -c <"$layer" | tr -d ' ')
	if [[ $number == 1 ]]; then
		paths='["/etc/removed"]'
	else
		paths='["/etc/layer-one","/etc/replaced"]'
	fi
	jq -n \
		--arg target "$target_id" \
		--argjson paths "$paths" \
		'{
		  schema: "org.volatoo.tombstones/v1",
		  target_id: $target,
		  paths: $paths
		}' |
		"$manifest" canonicalize - >"$work_dir/tombstones-$number.json"
	tombstone_digests[number]=$(
		canonical_digest "$work_dir/tombstones-$number.json"
	)
	tombstone_count=$(jq '.paths | length' "$work_dir/tombstones-$number.json")
	jq \
		--arg target "$target_id" \
		--arg context "$context_digest" \
		--arg layer "${layer_digests[$number]}" \
		--argjson size "${layer_sizes[$number]}" \
		--arg tombstones "${tombstone_digests[$number]}" \
		--argjson count "$tombstone_count" \
		'
		.target_id = $target
		| .build_context_digest = $context
		| .filesystem.rootfs_digest = $layer
		| .filesystem.rootfs_size = $size
		| .filesystem.tombstones_digest = $tombstones
		| .filesystem.tombstones_count = $count
		' \
		"$repo_root/update/examples/layer-transaction-v1.json" |
		"$manifest" canonicalize - >"$work_dir/transaction-$number.json"
	transaction_digests[number]=$(
		canonical_digest "$work_dir/transaction-$number.json"
	)
done

write_generation()
{
	local count=$1
	local output=$2
	jq -n \
		--arg target "$target_id" \
		--arg context "$context_digest" \
		--arg base "$base_digest" \
		--argjson base_size "$base_size" \
		--arg layer1 "${layer_digests[1]}" \
		--argjson layer1_size "${layer_sizes[1]}" \
		--arg tomb1 "${tombstone_digests[1]}" \
		--arg tx1 "${transaction_digests[1]}" \
		--arg layer2 "${layer_digests[2]}" \
		--argjson layer2_size "${layer_sizes[2]}" \
		--arg tomb2 "${tombstone_digests[2]}" \
		--arg tx2 "${transaction_digests[2]}" \
		--argjson count "$count" \
		'{
		  schema: "org.volatoo.generation/v1",
		  target_id: $target,
		  build_context_digest: $context,
		  base: {
		    rootfs_digest: $base,
		    rootfs_size: $base_size,
		    format: "squashfs"
		  },
		  layers: [
		    {
		      rootfs_digest: $layer1,
		      rootfs_size: $layer1_size,
		      format: "squashfs",
		      tombstones_digest: $tomb1,
		      transaction_digest: $tx1
		    },
		    {
		      rootfs_digest: $layer2,
		      rootfs_size: $layer2_size,
		      format: "squashfs",
		      tombstones_digest: $tomb2,
		      transaction_digest: $tx2
		    }
		  ][0:$count]
		}' |
		"$manifest" canonicalize - >"$output"
}

write_generation 1 "$work_dir/generation-1.json"
write_generation 2 "$work_dir/generation-2.json"
common_objects=(
	--object "$work_dir/context.json"
	--object "$base"
	--object "$work_dir/layer-output-1/layer.squashfs"
	--object "$work_dir/tombstones-1.json"
	--object "$work_dir/transaction-1.json"
)
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-1.json" \
	"${common_objects[@]}" \
	--activate >/dev/null
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-2.json" \
	"${common_objects[@]}" \
	--object "$work_dir/layer-output-2/layer.squashfs" \
	--object "$work_dir/tombstones-2.json" \
	--object "$work_dir/transaction-2.json" \
	--activate >/dev/null
source_generation=$(canonical_digest "$work_dir/generation-2.json")

"$repo_root/update/compact-generation-docker.sh" \
	--state "$state" \
	--output-dir "$work_dir/compacted" \
	--force \
	--activate
compacted_generation=$(canonical_digest "$work_dir/compacted/generation.json")
[[ $(<"$system/current") == "$compacted_generation" ]] ||
	fail "compacted generation was not selected"
[[ $(<"$system/previous") == "$source_generation" ]] ||
	fail "compaction did not preserve the source as previous"
jq -e \
	'.layer_count == 0 and .valid == true' \
	< <("$generation_tool" inspect --state "$state") >/dev/null ||
	fail "compacted generation still has layers"
[[ -f $system/compactions/${compacted_generation#sha256:}.json ]] ||
	fail "compaction receipt was not recorded"

docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/compacted/base.squashfs,dst=/base.squashfs,readonly" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		unsquashfs -no-progress -d /verify /base.squashfs >/dev/null
		test "$(cat /verify/etc/base)" = base
		test "$(cat /verify/etc/replaced)" = v2
		test "$(cat /verify/etc/layer-two)" = layer-two
		test ! -e /verify/etc/removed
		test ! -e /verify/etc/layer-one
	'

"$generation_tool" forget-previous \
	--state "$state" \
	--confirm "$source_generation" >/dev/null
gc_result=$("$generation_tool" gc --state "$state" --delete)
jq -e \
	'.garbage.manifests >= 2 and .garbage.objects >= 4' \
	<<<"$gc_result" >/dev/null ||
	fail "garbage collection did not reclaim the old layer chain"
"$generation_tool" inspect --state "$state" >/dev/null

echo "volatoo compaction Docker test passed"
