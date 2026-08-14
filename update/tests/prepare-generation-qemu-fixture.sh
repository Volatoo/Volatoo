#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage:
  update/tests/prepare-generation-qemu-fixture.sh \
    INIT_SYSTEM BASE_SQUASHFS BUILD_CONTEXT OUTPUT_DIRECTORY

Create a state image containing two selected generation-v2 fixtures.
INIT_SYSTEM must be openrc or systemd. The output directory receives
  state.ext4, current.digest, previous.digest and boot.digest.
  A realized fixture also writes realization.digest.

Optional environment variables:
  VOLATOO_STATE_SIZE  State filesystem size (default: 1G)
  VOLATOO_GENERATION_FIXTURE_CORRUPT_CURRENT
                       Corrupt the current-only layer: yes or no
  VOLATOO_GENERATION_FIXTURE_INTERRUPT_SELECTION
                       Simulate interruption before current replacement: yes or no
  VOLATOO_GENERATION_FIXTURE_REALIZE
                       Publish a complete realized closure: yes or no
  VOLATOO_GENERATION_FIXTURE_REALIZATION_VERSION
                       Realization contract for a realized fixture: 2 or 3
  VOLATOO_GENERATION_FIXTURE_SIGNING_KEY
                       Optional signify secret key for the realized closure
  VOLATOO_GENERATION_FIXTURE_TRUSTED_KEY
                       Matching signify public key; required with signing key
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
realize_generation=${VOLATOO_GENERATION_FIXTURE_REALIZE:-no}
realization_version=${VOLATOO_GENERATION_FIXTURE_REALIZATION_VERSION:-2}
signing_key=${VOLATOO_GENERATION_FIXTURE_SIGNING_KEY:-}
trusted_key=${VOLATOO_GENERATION_FIXTURE_TRUSTED_KEY:-}

if [[ $init_system != openrc && $init_system != systemd ]]; then
	echo "error: INIT_SYSTEM must be openrc or systemd" >&2
	exit 2
fi
for setting in "$corrupt_current" "$interrupt_selection" "$realize_generation"; do
	[[ $setting == yes || $setting == no ]] || {
		echo "error: fixture fault settings must be yes or no" >&2
		exit 2
	}
done
if [[ $realization_version != 2 && $realization_version != 3 ]]; then
	echo "error: fixture realization version must be 2 or 3" >&2
	exit 2
fi
if [[ $corrupt_current == yes && $interrupt_selection == yes ]]; then
	echo "error: select only one fixture fault" >&2
	exit 2
fi
if [[ $corrupt_current == yes && $realize_generation == yes ]]; then
	echo "error: corrupt-current and realized fixtures cannot be combined" >&2
	exit 2
fi
if [[ -n $signing_key || -n $trusted_key ]]; then
	[[ -n $signing_key && -n $trusted_key ]] || {
		echo "error: fixture signing and trusted keys are required together" >&2
		exit 2
	}
	[[ $realize_generation == yes ]] || {
		echo "error: fixture signing requires realization" >&2
		exit 2
	}
	for key_path in "$signing_key" "$trusted_key"; do
		[[ -f $key_path && ! -L $key_path ]] || {
			echo "error: fixture key is missing or unsafe: $key_path" >&2
			exit 1
		}
	done
	signing_key=$(cd -- "$(dirname -- "$signing_key")" && pwd)/$(basename -- "$signing_key")
	trusted_key=$(cd -- "$(dirname -- "$trusted_key")" && pwd)/$(basename -- "$trusted_key")
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
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
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
for name in \
	state.ext4 \
	current.digest \
	previous.digest \
	boot.digest \
	realization.digest \
	realization-rootfs.digest \
	verity-hash.digest \
	parent-tree-receipt.digest \
	validation-index.digest \
	validation-index \
	tree-state.digest \
	tree-state \
	reuse-report \
	signature-key.digest
do
	[[ ! -e $output_dir/$name ]] || {
		echo "error: output already exists: $output_dir/$name" >&2
		exit 1
	}
done
base_image=$(cd -- "$(dirname -- "$base_image")" && pwd)/$(basename -- "$base_image")

python3 "$fixture_tool" context \
	--build-context "$context_source" \
	--base "$base_image" \
	--output-dir "$work_dir/provenance"
context=$work_dir/provenance/build-context.json
build_spec=$work_dir/provenance/build-spec.json
source_catalog=$work_dir/provenance/source-catalog.json
acquisition=$work_dir/provenance/acquisition.json
base_generation=$work_dir/provenance/base-generation.json
target_id=$(jq -r '.target.id' "$context")
case $target_id in
	*/"$init_system"/*) ;;
	*)
		echo "error: build context does not select $init_system: $target_id" >&2
		exit 1
		;;
esac

mkdir -p \
	"$work_dir/layer-root-1/etc" \
	"$work_dir/layer-root-1/usr/libexec" \
	"$work_dir/layer-root-2/etc" \
	"$work_dir/compressed-1" \
	"$work_dir/compressed-2"
printf 'layer-one\n' >"$work_dir/layer-root-1/etc/volatoo-layer-one"
printf 'replacement-v1\n' >"$work_dir/layer-root-1/etc/volatoo-replaced"
cp "$repo_root/update/volatoo-update-view" \
	"$work_dir/layer-root-1/usr/libexec/volatoo-update-view"
chmod 0755 "$work_dir/layer-root-1/usr/libexec/volatoo-update-view"

# Emit an init-owned readiness marker before the test waits for a serial
# login. This separates service startup from QEMU tty discovery latency.
printf '%s\n' \
	'#!/bin/sh' \
	'printf "[volatoo] service readiness reached\n" >/dev/console' \
	>"$work_dir/layer-root-1/usr/libexec/volatoo-qemu-ready"
chmod 0755 "$work_dir/layer-root-1/usr/libexec/volatoo-qemu-ready"
if [[ $init_system == openrc ]]; then
	mkdir -p \
		"$work_dir/layer-root-1/etc/init.d" \
		"$work_dir/layer-root-1/etc/runlevels/boot"
	printf '%s\n' \
		'#!/sbin/openrc-run' \
		'description="Report Volatoo QEMU service readiness"' \
		'' \
		'depend() {' \
		'    need localmount' \
		'    after bootmisc' \
		'}' \
		'' \
		'start() {' \
		'    ebegin "Reporting Volatoo QEMU service readiness"' \
		'    /usr/libexec/volatoo-qemu-ready' \
		'    eend $?' \
		'}' \
		>"$work_dir/layer-root-1/etc/init.d/volatoo-qemu-ready"
	chmod 0755 "$work_dir/layer-root-1/etc/init.d/volatoo-qemu-ready"
	ln -s /etc/init.d/volatoo-qemu-ready \
		"$work_dir/layer-root-1/etc/runlevels/boot/volatoo-qemu-ready"
else
	mkdir -p \
		"$work_dir/layer-root-1/etc/systemd/system/basic.target.wants" \
		"$work_dir/layer-root-1/usr/lib/systemd/system"
	printf '%s\n' \
		'[Unit]' \
		'Description=Report Volatoo QEMU service readiness' \
		'DefaultDependencies=no' \
		'After=local-fs.target systemd-udev-trigger.service' \
		'Before=basic.target' \
		'' \
		'[Service]' \
		'Type=oneshot' \
		'ExecStart=/usr/libexec/volatoo-qemu-ready' \
		'' \
		'[Install]' \
		'WantedBy=basic.target' \
		>"$work_dir/layer-root-1/usr/lib/systemd/system/volatoo-qemu-ready.service"
	ln -s /usr/lib/systemd/system/volatoo-qemu-ready.service \
		"$work_dir/layer-root-1/etc/systemd/system/basic.target.wants/volatoo-qemu-ready.service"
fi
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

for number in 1 2; do
	jq -n \
		--arg target "$target_id" \
		--arg first "/etc/volatoo-layer-$number" \
		--arg second /etc/volatoo-replaced \
		--arg update_view /usr/libexec/volatoo-update-view \
		--argjson number "$number" \
		'{
		  schema: "org.volatoo.layer-paths/v1",
		  target_id: $target,
		  paths: (
		    [$first, $second]
		    + if $number == 1 then [$update_view] else [] end
		  )
		}' |
		"$manifest" canonicalize - >"$work_dir/changed-$number.json"
done

python3 "$fixture_tool" layer \
	--generation-version 2 \
	--build-context "$context" \
	--build-spec "$build_spec" \
	--acquisition "$acquisition" \
	--parent "$base_generation" \
	--changed-paths "$work_dir/changed-1.json" \
	--tombstones "$work_dir/tombstones-1.json" \
	--layer "$work_dir/compressed-1/layer.squashfs" \
	--output-dir "$work_dir/generation-1"
python3 "$fixture_tool" layer \
	--generation-version 2 \
	--build-context "$context" \
	--build-spec "$build_spec" \
	--acquisition "$acquisition" \
	--parent "$work_dir/generation-1/generation.json" \
	--changed-paths "$work_dir/changed-2.json" \
	--tombstones "$work_dir/tombstones-2.json" \
	--layer "$work_dir/compressed-2/layer.squashfs" \
	--output-dir "$work_dir/generation-2"

declare -a layer_digests=()
for number in 1 2; do
	layer_digests[number]=$(
		raw_digest "$work_dir/compressed-$number/layer.squashfs"
	)
done

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
	--object "$context"
	--object "$build_spec"
	--object "$source_catalog"
	--object "$acquisition"
	--object "$base_image"
	--object "$work_dir/compressed-1/layer.squashfs"
	--object "$work_dir/changed-1.json"
	--object "$work_dir/tombstones-1.json"
	--object "$work_dir/generation-1/transaction.json"
	--object "$work_dir/generation-1/portage-state.json"
)
"$generation_tool" publish \
	--state "$state_root" \
	--generation "$base_generation" \
	--object "$context" \
	--object "$base_image" \
	--activate \
	--expected-current none >/dev/null
base_generation_digest=$(canonical_digest "$base_generation")
"$generation_tool" publish \
	--state "$state_root" \
	--generation "$work_dir/generation-1/generation.json" \
	"${common_objects[@]}" \
	--activate \
	--expected-current "$base_generation_digest" >/dev/null
previous_digest=$(
	canonical_digest "$work_dir/generation-1/generation.json"
)
"$generation_tool" publish \
	--state "$state_root" \
	--generation "$work_dir/generation-2/generation.json" \
	"${common_objects[@]}" \
	--object "$work_dir/compressed-2/layer.squashfs" \
	--object "$work_dir/changed-2.json" \
	--object "$work_dir/tombstones-2.json" \
	--object "$work_dir/generation-2/transaction.json" \
	--object "$work_dir/generation-2/portage-state.json" \
	--activate \
	--expected-current "$previous_digest" >/dev/null

current_digest=$(canonical_digest "$work_dir/generation-2/generation.json")
if [[ $realize_generation == yes ]]; then
	declare -a realization_arguments=()
	if [[ -n $signing_key ]]; then
		realization_arguments+=(
			--signing-key "$signing_key"
			--trusted-key "$trusted_key"
		)
	fi
	if [[ $realization_version == 3 ]]; then
		VOLATOO_LAYER_COMPRESSOR_IMAGE=$compressor_image \
			"$repo_root/update/realize-generation-incremental-docker.sh" \
			--state "$state_root" \
			--generation "$previous_digest" \
			--output-dir "$work_dir/realized-parent" \
			"${realization_arguments[@]}"
		VOLATOO_LAYER_COMPRESSOR_IMAGE=$compressor_image \
			"$repo_root/update/realize-generation-incremental-docker.sh" \
			--state "$state_root" \
			--generation "$current_digest" \
			--output-dir "$work_dir/realized" \
			"${realization_arguments[@]}"
	else
		VOLATOO_LAYER_COMPRESSOR_IMAGE=$compressor_image \
			"$repo_root/update/realize-generation-docker.sh" \
			--state "$state_root" \
			--generation "$current_digest" \
			--output-dir "$work_dir/realized" \
			"${realization_arguments[@]}"
	fi
fi
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

default_state_size=1G
if [[ $realize_generation == yes ]]; then
	default_state_size=2G
fi
VOLATOO_STATE_SIZE=${VOLATOO_STATE_SIZE:-$default_state_size} \
	"$repo_root/scripts/build-state-image.sh" \
	--source "$state_root" \
	"$output_dir/state.ext4" >/dev/null
cp "$state_root/volatoo/system/current" "$output_dir/current.digest"
cp "$state_root/volatoo/system/previous" "$output_dir/previous.digest"
printf '%s\n' "$boot_digest" >"$output_dir/boot.digest"
if [[ $realize_generation == yes ]]; then
	cp \
		"$state_root/volatoo/system/realizations/${current_digest#sha256:}" \
		"$output_dir/realization.digest"
	realization_inspection=$(
		"$generation_tool" inspect \
			--state "$state_root" \
			"$current_digest"
	)
	jq -er --argjson version "$realization_version" \
		'.realization.contract_version == $version' \
		<<<"$realization_inspection" >/dev/null
	jq -r \
		'if .realization.contract_version == 3
		 then .realization.images[-1].rootfs_digest
		 else .realization.rootfs_digest
		 end' \
		<<<"$realization_inspection" \
		>"$output_dir/realization-rootfs.digest"
	jq -r \
		'if .realization.contract_version == 3
		 then .realization.images[0].verity.hash_digest
		 else .realization.verity.hash_digest
		 end' \
		<<<"$realization_inspection" \
		>"$output_dir/verity-hash.digest"
	if [[ $realization_version == 3 ]]; then
		jq -er '
			.realization.parent_tree_receipt.contract_version == 3
			and .realization.parent_tree_receipt.validation == "indexed-fhs-elf-v1"
			and (.realization.parent_tree_receipt.validation_index_size > 0)
			and (.realization.parent_tree_receipt.tree_state_size > 0)
			and .realization.parent_tree_receipt.tree_state.composition == "generation-plan-and-index-v1"
		' \
			<<<"$realization_inspection" >/dev/null
		jq -r '.realization.tree_receipt_digest' \
			<<<"$realization_inspection" \
			>"$output_dir/parent-tree-receipt.digest"
		jq -r '.realization.parent_tree_receipt.validation_index_digest' \
			<<<"$realization_inspection" \
			>"$output_dir/validation-index.digest"
		cp "$work_dir/realized/validation-index" \
			"$output_dir/validation-index"
		jq -r '.realization.parent_tree_receipt.tree_state_digest' \
			<<<"$realization_inspection" \
			>"$output_dir/tree-state.digest"
		cp "$work_dir/realized/tree-state" "$output_dir/tree-state"
		cp "$work_dir/realized/reuse-report" "$output_dir/reuse-report"
		grep -Fx 'reused 2' "$output_dir/reuse-report" >/dev/null
		grep -Fx 'generated 1' "$output_dir/reuse-report" >/dev/null
		grep -E '^validation indexed-delta(-audited)?$' \
			"$output_dir/reuse-report" >/dev/null
	fi
	if [[ -n $trusted_key ]]; then
		trusted_key_digest=$(raw_digest "$trusted_key")
		jq -e \
			--arg key "$trusted_key_digest" \
			'.realization.signatures | map(.key_id) | index($key) != null' \
			<<<"$realization_inspection" >/dev/null
		printf '%s\n' "$trusted_key_digest" \
			>"$output_dir/signature-key.digest"
	fi
fi

echo "prepared $init_system generation fixture: $output_dir/state.ext4"
