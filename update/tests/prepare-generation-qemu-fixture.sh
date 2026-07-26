#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage:
  update/tests/prepare-generation-qemu-fixture.sh \
    INIT_SYSTEM BASE_SQUASHFS BUILD_CONTEXT OUTPUT_DIRECTORY

Create a layout-v2 state image containing two selected fixture generations.
INIT_SYSTEM must be openrc or systemd. The output directory receives
  state.ext4, current.digest, previous.digest and boot.digest.

Optional environment variables:
  VOLATOO_STATE_SIZE  State filesystem size (default: 1G)
  VOLATOO_GENERATION_FIXTURE_CORRUPT_CURRENT
                       Corrupt the current-only layer: yes or no
  VOLATOO_GENERATION_FIXTURE_INTERRUPT_SELECTION
                       Simulate interruption before current replacement: yes or no
EOF
}

if (( $# != 4 )); then
	usage >&2
	exit 2
fi

init_system=$1
base_image=$2
context_source=$3
output_dir=$4
corrupt_current=${VOLATOO_GENERATION_FIXTURE_CORRUPT_CURRENT:-no}
interrupt_selection=${VOLATOO_GENERATION_FIXTURE_INTERRUPT_SELECTION:-no}

if [[ $init_system != openrc && $init_system != systemd ]]; then
	echo "error: INIT_SYSTEM must be openrc or systemd" >&2
	exit 2
fi
for setting in "$corrupt_current" "$interrupt_selection"; do
	[[ $setting == yes || $setting == no ]] || {
		echo "error: fixture fault settings must be yes or no" >&2
		exit 2
	}
done
if [[ $corrupt_current == yes && $interrupt_selection == yes ]]; then
	echo "error: select only one fixture fault" >&2
	exit 2
fi
for path in "$base_image" "$context_source"; do
	[[ -f $path ]] || {
		echo "error: input does not exist: $path" >&2
		exit 1
	}
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
manifest=$repo_root/update/volatoo-manifest
generation_tool=$repo_root/update/volatoo-generation
compressor_image=volatoo-layer-compressor:generation-qemu
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-generation-qemu.XXXXXX")

cleanup()
{
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

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

mkdir -p "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
for name in state.ext4 current.digest previous.digest boot.digest; do
	[[ ! -e $output_dir/$name ]] || {
		echo "error: output already exists: $output_dir/$name" >&2
		exit 1
	}
done
base_image=$(cd -- "$(dirname -- "$base_image")" && pwd)/$(basename -- "$base_image")

"$manifest" canonicalize "$context_source" >"$work_dir/context.json"
target_id=$(jq -r '.target.id' "$work_dir/context.json")
case $target_id in
	*/"$init_system"/*) ;;
	*)
		echo "error: build context does not select $init_system: $target_id" >&2
		exit 1
		;;
esac
context_digest=$(canonical_digest "$work_dir/context.json")
base_digest=$(raw_digest "$base_image")
base_size=$(wc -c <"$base_image" | tr -d ' ')

mkdir -p \
	"$work_dir/layer-root-1/etc" \
	"$work_dir/layer-root-2/etc" \
	"$work_dir/compressed-1" \
	"$work_dir/compressed-2"
printf 'layer-one\n' >"$work_dir/layer-root-1/etc/volatoo-layer-one"
printf 'replacement-v1\n' >"$work_dir/layer-root-1/etc/volatoo-replaced"
printf 'replacement-v2\n' >"$work_dir/layer-root-2/etc/volatoo-replaced"
printf 'layer-two\n' >"$work_dir/layer-root-2/etc/volatoo-layer-two"

docker build \
	--platform linux/amd64 \
	--tag "$compressor_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root" >/dev/null
for number in 1 2; do
	docker run --rm \
		--platform linux/amd64 \
		--mount "type=bind,src=$work_dir/layer-root-$number,dst=/input,readonly" \
		--mount "type=bind,src=$work_dir/compressed-$number,dst=/output" \
		"$compressor_image" >/dev/null
done

jq -n \
	--arg target "$target_id" \
	'{
	  schema: "org.volatoo.tombstones/v1",
	  target_id: $target,
	  paths: []
	}' |
	"$manifest" canonicalize - >"$work_dir/tombstones-1.json"
jq -n \
	--arg target "$target_id" \
	'{
	  schema: "org.volatoo.tombstones/v1",
	  target_id: $target,
	  paths: [
	    "/etc/volatoo-layer-one",
	    "/etc/volatoo-replaced"
	  ]
	}' |
	"$manifest" canonicalize - >"$work_dir/tombstones-2.json"

declare -a layer_digests=()
declare -a layer_sizes=()
declare -a tombstone_digests=()
declare -a transaction_digests=()
for number in 1 2; do
	layer=$work_dir/compressed-$number/layer.squashfs
	layer_digests[number]=$(raw_digest "$layer")
	layer_sizes[number]=$(wc -c <"$layer" | tr -d ' ')
	tombstone_digests[number]=$(
		canonical_digest "$work_dir/tombstones-$number.json"
	)
	tombstone_count=$(jq '.paths | length' "$work_dir/tombstones-$number.json")
	jq \
		--arg target "$target_id" \
		--arg context_digest "$context_digest" \
		--arg rootfs_digest "${layer_digests[$number]}" \
		--argjson rootfs_size "${layer_sizes[$number]}" \
		--arg tombstones_digest "${tombstone_digests[$number]}" \
		--argjson tombstones_count "$tombstone_count" \
		'
		.target_id = $target
		| .build_context_digest = $context_digest
		| .filesystem.rootfs_digest = $rootfs_digest
		| .filesystem.rootfs_size = $rootfs_size
		| .filesystem.tombstones_digest = $tombstones_digest
		| .filesystem.tombstones_count = $tombstones_count
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
		--arg context_digest "$context_digest" \
		--arg base_digest "$base_digest" \
		--argjson base_size "$base_size" \
		--arg layer_one_digest "${layer_digests[1]}" \
		--argjson layer_one_size "${layer_sizes[1]}" \
		--arg tombstone_one_digest "${tombstone_digests[1]}" \
		--arg transaction_one_digest "${transaction_digests[1]}" \
		--arg layer_two_digest "${layer_digests[2]}" \
		--argjson layer_two_size "${layer_sizes[2]}" \
		--arg tombstone_two_digest "${tombstone_digests[2]}" \
		--arg transaction_two_digest "${transaction_digests[2]}" \
		--argjson count "$count" \
		'{
		  schema: "org.volatoo.generation/v1",
		  target_id: $target,
		  build_context_digest: $context_digest,
		  base: {
		    rootfs_digest: $base_digest,
		    rootfs_size: $base_size,
		    format: "squashfs"
		  },
		  layers: [
		    {
		      rootfs_digest: $layer_one_digest,
		      rootfs_size: $layer_one_size,
		      format: "squashfs",
		      tombstones_digest: $tombstone_one_digest,
		      transaction_digest: $transaction_one_digest
		    },
		    {
		      rootfs_digest: $layer_two_digest,
		      rootfs_size: $layer_two_size,
		      format: "squashfs",
		      tombstones_digest: $tombstone_two_digest,
		      transaction_digest: $transaction_two_digest
		    }
		  ][0:$count]
		}' |
		"$manifest" canonicalize - >"$output"
}

write_generation 1 "$work_dir/generation-1.json"
write_generation 2 "$work_dir/generation-2.json"

state_root=$work_dir/state-root
mkdir -p \
	"$state_root/volatoo/config" \
	"$state_root/volatoo/data/bind" \
	"$state_root/volatoo/data/identity" \
	"$state_root/volatoo/data/overlay" \
	"$state_root/volatoo/data/sync" \
	"$state_root/volatoo/snapshots"
printf '1\n' >"$state_root/volatoo/layout-version"
"$generation_tool" migrate-state --state "$state_root" >/dev/null

common_objects=(
	--object "$work_dir/context.json"
	--object "$base_image"
	--object "$work_dir/compressed-1/layer.squashfs"
	--object "$work_dir/tombstones-1.json"
	--object "$work_dir/transaction-1.json"
)
"$generation_tool" publish \
	--state "$state_root" \
	--generation "$work_dir/generation-1.json" \
	"${common_objects[@]}" \
	--activate >/dev/null
"$generation_tool" publish \
	--state "$state_root" \
	--generation "$work_dir/generation-2.json" \
	"${common_objects[@]}" \
	--object "$work_dir/compressed-2/layer.squashfs" \
	--object "$work_dir/tombstones-2.json" \
	--object "$work_dir/transaction-2.json" \
	--activate >/dev/null

current_digest=$(canonical_digest "$work_dir/generation-2.json")
previous_digest=$(canonical_digest "$work_dir/generation-1.json")
if [[ $interrupt_selection == yes ]]; then
	# This is the durable intermediate state after previous was written but
	# before current was atomically replaced during a gen1 -> gen2 selection.
	printf '%s\n' "$previous_digest" >"$state_root/volatoo/system/current"
	printf '%s\n' "$previous_digest" >"$state_root/volatoo/system/previous"
elif [[ $corrupt_current == yes ]]; then
	current_layer_object=$state_root/volatoo/system/objects/sha256/${layer_digests[2]#sha256:}
	chmod u+w "$current_layer_object"
	printf 'corrupt current layer\n' >"$current_layer_object"
fi
boot_digest=$(
	"$generation_tool" resolve --state "$state_root" \
		2>"$work_dir/resolve.stderr"
)
if [[ $corrupt_current == yes ]]; then
	[[ $boot_digest == "$previous_digest" ]]
	grep -q 'selected previous' "$work_dir/resolve.stderr"
elif [[ $interrupt_selection == yes ]]; then
	[[ $boot_digest == "$previous_digest" ]]
else
	[[ $boot_digest == "$current_digest" ]]
fi

VOLATOO_STATE_SIZE=${VOLATOO_STATE_SIZE:-1G} \
	"$repo_root/scripts/build-state-image.sh" \
	--source "$state_root" \
	"$output_dir/state.ext4" >/dev/null
cp "$state_root/volatoo/system/current" "$output_dir/current.digest"
cp "$state_root/volatoo/system/previous" "$output_dir/previous.digest"
printf '%s\n' "$boot_digest" >"$output_dir/boot.digest"

echo "prepared $init_system generation fixture: $output_dir/state.ext4"
