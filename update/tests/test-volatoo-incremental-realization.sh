#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-incremental-realization.XXXXXX")
trap 'find "$work_dir" -depth -delete 2>/dev/null || true' EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

expect_failure()
{
	expected=$1
	shift
	set +e
	output=$("$@" 2>&1)
	status=$?
	set -e
	[[ $status -eq 1 ]] || fail "expected status 1, got $status: $*"
	grep -Fq -- "$expected" <<<"$output" ||
		fail "expected '$expected' in: $output"
}

sha256_file()
{
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print "sha256:" $1 }'
	else
		shasum -a 256 "$1" | awk '{ print "sha256:" $1 }'
	fi
}

state=$work_dir/state
mkdir -p \
	"$state/volatoo/config" \
	"$state/volatoo/data/bind" \
	"$state/volatoo/data/identity" \
	"$state/volatoo/data/overlay" \
	"$state/volatoo/data/sync" \
	"$state/volatoo/snapshots"
printf '1\n' >"$state/volatoo/layout-version"
"$generation_tool" migrate-state --state "$state" >/dev/null

printf 'hsqs' >"$work_dir/base.squashfs"
truncate -s 4096 "$work_dir/base.squashfs"
truncate -s 4096 "$work_dir/base.verity"
python3 "$fixture_tool" context \
	--build-context "$repo_root/update/examples/build-context-v1.json" \
	--base "$work_dir/base.squashfs" \
	--output-dir "$work_dir/context"
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/context/base-generation.json" \
	--object "$work_dir/context/build-context.json" \
	--object "$work_dir/base.squashfs" \
	--activate \
	--expected-current none >/dev/null

inspection=$("$generation_tool" inspect --state "$state" current)
generation_digest=$(jq -r '.generation_digest' <<<"$inspection")
boot_plan_digest=$(jq -r '.boot_plan_digest' <<<"$inspection")
target_id=$(jq -r '.target_id' <<<"$inspection")
context_digest=$(jq -r '.build_context_digest' <<<"$inspection")
base_digest=$(jq -r '.base.rootfs_digest' <<<"$inspection")
hash_digest=$(sha256_file "$work_dir/base.verity")
root_hash=$(printf 'a%.0s' {1..64})
tree_digest=sha256:$(printf 'b%.0s' {1..64})
salt=${base_digest#sha256:}

{
	printf 'VOLATOO_PARENT_TREE_RECEIPT_V1\n'
	printf 'generation %s\n' "$generation_digest"
	printf 'boot-plan %s\n' "$boot_plan_digest"
	printf 'parent-generation none\n'
	printf 'parent-realization none\n'
	printf 'target %s\n' "$target_id"
	printf 'context %s\n' "$context_digest"
	printf 'tree %s\n' "$tree_digest"
	printf 'fhs org.volatoo.gentoo-fhs/v1\n'
	printf 'validation full-fhs-elf-v1\n'
	printf 'end\n'
} >"$work_dir/parent-tree.receipt"
tree_receipt_digest=$(sha256_file "$work_dir/parent-tree.receipt")

write_plan()
{
	source_digest=$1
	output=$2
	{
		printf 'VOLATOO_REALIZATION_V3\n'
		printf 'generation %s\n' "$generation_digest"
		printf 'boot-plan %s\n' "$boot_plan_digest"
		printf 'target %s\n' "$target_id"
		printf 'context %s\n' "$context_digest"
		printf 'tree %s\n' "$tree_digest"
		printf 'tree-receipt %s\n' "$tree_receipt_digest"
		printf 'fhs org.volatoo.gentoo-fhs/v1\n'
		printf 'composition overlayfs-lowerdir whiteout-char-0-0\n'
		printf 'image 0 base %s %s 4096 %s 4096 %s %s 1\n' \
			"$source_digest" \
			"$base_digest" \
			"$hash_digest" \
			"$root_hash" \
			"$salt"
		printf 'verity-format 1 sha256 4096 4096 no-superblock\n'
		printf 'builder squashfs-tools 4.7.5 zstd 19 1048576 reproducible\n'
		printf 'end\n'
	} >"$output"
}

write_plan "$base_digest" "$work_dir/realization.plan"
"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$generation_digest" \
	--plan "$work_dir/realization.plan" \
	--object "$work_dir/parent-tree.receipt" \
	--object "$work_dir/base.verity" >/dev/null

inspection=$("$generation_tool" inspect --state "$state" current)
jq -e \
	--arg base "$base_digest" \
	--arg hash "$hash_digest" \
	'
		.realization.contract_version == 3
		and .realization.composition == "overlayfs-lowerdir"
		and .realization.whiteout_format == "char-0-0"
		and (.realization.images | length) == 1
		and .realization.images[0].source_digest == $base
		and .realization.images[0].rootfs_digest == $base
		and .realization.images[0].verity.hash_digest == $hash
		and .realization.parent_tree_receipt.validation == "full-fhs-elf-v1"
		and .realization.parent_tree_receipt.parent_generation_digest == null
	' <<<"$inspection" >/dev/null ||
	fail "inspection did not expose the incremental realization"

parent_realization_digest=$(jq -r '.realization.realization_digest' <<<"$inspection")
printf 'hsqs-child-layer' >"$work_dir/layer.squashfs"
truncate -s 4096 "$work_dir/layer.squashfs"
printf 'layer-verity' >"$work_dir/layer.verity"
truncate -s 4096 "$work_dir/layer.verity"
python3 "$fixture_tool" layer \
	--build-context "$work_dir/context/build-context.json" \
	--build-spec "$work_dir/context/build-spec.json" \
	--acquisition "$work_dir/context/acquisition.json" \
	--parent "$work_dir/context/base-generation.json" \
	--changed-paths "$repo_root/update/examples/layer-paths-v1.json" \
	--tombstones "$repo_root/update/examples/tombstones-v1.json" \
	--layer "$work_dir/layer.squashfs" \
	--generation-version 2 \
	--output-dir "$work_dir/child"
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/child/generation.json" \
	--object "$work_dir/context/build-spec.json" \
	--object "$work_dir/context/acquisition.json" \
	--object "$work_dir/context/source-catalog.json" \
	--object "$repo_root/update/examples/layer-paths-v1.json" \
	--object "$repo_root/update/examples/tombstones-v1.json" \
	--object "$work_dir/child/transaction.json" \
	--object "$work_dir/child/portage-state.json" \
	--object "$work_dir/layer.squashfs" >/dev/null

child_inspection=$("$generation_tool" inspect --state "$state" \
	"$(sha256_file "$work_dir/child/generation.json")")
child_generation_digest=$(jq -r '.generation_digest' <<<"$child_inspection")
child_boot_plan_digest=$(jq -r '.boot_plan_digest' <<<"$child_inspection")
layer_digest=$(jq -r '.layers[0].rootfs_digest' <<<"$child_inspection")
layer_hash_digest=$(sha256_file "$work_dir/layer.verity")
layer_salt=${layer_digest#sha256:}
layer_root_hash=$(printf 'd%.0s' {1..64})
{
	printf 'VOLATOO_FHS_ELF_INDEX_V1\n'
	printf 'target %s\n' "$target_id"
	printf 'P|/|d|755\n'
	printf 'end\n'
} >"$work_dir/child-validation.index"
child_validation_index_digest=$(sha256_file "$work_dir/child-validation.index")
child_validation_index_size=$(wc -c <"$work_dir/child-validation.index" | tr -d ' ')
{
	printf 'VOLATOO_TREE_STATE_V1\n'
	printf 'generation %s\n' "$child_generation_digest"
	printf 'boot-plan %s\n' "$child_boot_plan_digest"
	printf 'parent-state none\n'
	printf 'target %s\n' "$target_id"
	printf 'context %s\n' "$context_digest"
	printf 'validation-index %s %s\n' \
		"$child_validation_index_digest" "$child_validation_index_size"
	printf 'composition generation-plan-and-index-v1\n'
	printf 'end\n'
} >"$work_dir/child-tree.state"
child_tree_digest=$(sha256_file "$work_dir/child-tree.state")
child_tree_state_size=$(wc -c <"$work_dir/child-tree.state" | tr -d ' ')
{
	printf 'VOLATOO_PARENT_TREE_RECEIPT_V3\n'
	printf 'generation %s\n' "$child_generation_digest"
	printf 'boot-plan %s\n' "$child_boot_plan_digest"
	printf 'parent-generation %s\n' "$generation_digest"
	printf 'parent-realization %s\n' "$parent_realization_digest"
	printf 'target %s\n' "$target_id"
	printf 'context %s\n' "$context_digest"
	printf 'tree %s\n' "$child_tree_digest"
	printf 'fhs org.volatoo.gentoo-fhs/v1\n'
	printf 'validation-index %s %s\n' \
		"$child_validation_index_digest" "$child_validation_index_size"
	printf 'tree-state %s %s\n' \
		"$child_tree_digest" "$child_tree_state_size"
	printf 'validation indexed-fhs-elf-v1\n'
	printf 'end\n'
} >"$work_dir/child-parent-tree.receipt"
child_receipt_digest=$(sha256_file "$work_dir/child-parent-tree.receipt")
{
	printf 'VOLATOO_REALIZATION_V3\n'
	printf 'generation %s\n' "$child_generation_digest"
	printf 'boot-plan %s\n' "$child_boot_plan_digest"
	printf 'target %s\n' "$target_id"
	printf 'context %s\n' "$context_digest"
	printf 'tree %s\n' "$child_tree_digest"
	printf 'tree-receipt %s\n' "$child_receipt_digest"
	printf 'fhs org.volatoo.gentoo-fhs/v1\n'
	printf 'composition overlayfs-lowerdir whiteout-char-0-0\n'
	printf 'image 0 base %s %s 4096 %s 4096 %s %s 1\n' \
		"$base_digest" "$base_digest" "$hash_digest" "$root_hash" "$salt"
	printf 'image 1 layer %s %s 4096 %s 4096 %s %s 1\n' \
		"$layer_digest" "$layer_digest" "$layer_hash_digest" \
		"$layer_root_hash" "$layer_salt"
	printf 'verity-format 1 sha256 4096 4096 no-superblock\n'
	printf 'builder squashfs-tools 4.7.5 zstd 19 1048576 reproducible\n'
	printf 'end\n'
} >"$work_dir/child-realization.plan"
expect_failure "is missing or unsafe" \
	"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$child_generation_digest" \
	--plan "$work_dir/child-realization.plan" \
	--object "$work_dir/child-parent-tree.receipt" \
	--object "$work_dir/layer.verity"
"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$child_generation_digest" \
	--plan "$work_dir/child-realization.plan" \
	--object "$work_dir/child-parent-tree.receipt" \
	--object "$work_dir/child-validation.index" \
	--object "$work_dir/child-tree.state" \
	--object "$work_dir/layer.verity" >/dev/null
child_inspection=$("$generation_tool" inspect \
	--state "$state" "$child_generation_digest")
jq -e \
	--arg parent "$generation_digest" \
	--arg parent_realization "$parent_realization_digest" \
	--arg index "$child_validation_index_digest" \
	--arg state "$child_tree_digest" \
	'.realization.contract_version == 3
	 and (.realization.images | length) == 2
	 and .realization.parent_tree_receipt.contract_version == 3
	 and .realization.parent_tree_receipt.validation == "indexed-fhs-elf-v1"
	 and .realization.parent_tree_receipt.validation_index_digest == $index
	 and .realization.parent_tree_receipt.tree_state_digest == $state
	 and .realization.parent_tree_receipt.tree_state.parent_tree_state_digest == null
	 and .realization.parent_tree_receipt.parent_generation_digest == $parent
	 and .realization.parent_tree_receipt.parent_realization_digest == $parent_realization' \
	<<<"$child_inspection" >/dev/null ||
	fail "direct-parent receipt did not publish an inherited v3 stack"

parent_realization_pointer=$state/volatoo/system/realizations/${generation_digest#sha256:}
chmod u+w "$parent_realization_pointer"
printf 'sha256:%064d\n' 0 >"$parent_realization_pointer"
expect_failure "parent-tree receipt realization pointer changed" \
	"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$child_generation_digest" \
	--plan "$work_dir/child-realization.plan" \
	--object "$work_dir/child-parent-tree.receipt" \
	--object "$work_dir/child-tree.state" \
	--object "$work_dir/layer.verity"
printf '%s\n' "$parent_realization_digest" >"$parent_realization_pointer"
chmod 0444 "$parent_realization_pointer"

"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$generation_digest" \
	--plan "$work_dir/realization.plan" \
	--object "$work_dir/base.verity" >/dev/null

if command -v signify >/dev/null 2>&1; then
	signify -G -n \
		-p "$work_dir/release.pub" \
		-s "$work_dir/release.sec"
	"$generation_tool" sign-realization \
		--state "$state" \
		--generation "$generation_digest" \
		--secret-key "$work_dir/release.sec" \
		--trusted-key "$work_dir/release.pub" \
		--signify "$(command -v signify)" >/dev/null
	signed_scrub=$(
		"$generation_tool" scrub \
			--state "$state" \
			--trusted-key "$work_dir/release.pub" \
			--require-signature \
			--signify "$(command -v signify)"
	)
	jq -e \
		'.status == "verified" and .trusted_signatures == 1' \
		<<<"$signed_scrub" >/dev/null ||
		fail "trusted scrub did not verify the incremental realization"
fi

wrong_digest=sha256:$(printf 'c%.0s' {1..64})
write_plan "$wrong_digest" "$work_dir/wrong-source.plan"
expect_failure "image source binding differs" \
	"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$generation_digest" \
	--plan "$work_dir/wrong-source.plan"

printf 'unexpected\n' >"$work_dir/unexpected.object"
expect_failure "not referenced by the plan" \
	"$generation_tool" record-incremental-realization \
	--state "$state" \
	--generation "$generation_digest" \
	--plan "$work_dir/realization.plan" \
	--object "$work_dir/unexpected.object"

validation_index_object=$state/volatoo/system/objects/sha256/${child_validation_index_digest#sha256:}
cp "$validation_index_object" "$work_dir/validation-index.backup"
chmod u+w "$validation_index_object"
printf 'corrupt\n' >>"$validation_index_object"
expect_failure "object digest mismatch" \
	"$generation_tool" inspect --state "$state" "$child_generation_digest"
cp "$work_dir/validation-index.backup" "$validation_index_object"
chmod 0444 "$validation_index_object"

tree_state_object=$state/volatoo/system/objects/sha256/${child_tree_digest#sha256:}
cp "$tree_state_object" "$work_dir/tree-state.backup"
chmod u+w "$tree_state_object"
printf 'corrupt\n' >>"$tree_state_object"
expect_failure "object digest mismatch" \
	"$generation_tool" inspect --state "$state" "$child_generation_digest"
cp "$work_dir/tree-state.backup" "$tree_state_object"
chmod 0444 "$tree_state_object"

scrub=$("$generation_tool" scrub --state "$state")
jq -e \
	'.status == "verified" and .generations == 1 and .objects >= 5' \
	<<<"$scrub" >/dev/null ||
	fail "scrub did not retain the incremental realization closure"

echo "Volatoo incremental realization tests passed"
