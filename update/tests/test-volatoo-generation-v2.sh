#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
manifest_tool=$repo_root/update/volatoo-manifest
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-generation-v2.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

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

canonical_digest()
{
	"$manifest_tool" digest "$1"
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

printf 'hsqsv2-base\n' >"$work_dir/base.squashfs"
printf 'hsqsv2-layer-one\n' >"$work_dir/layer-1.squashfs"
printf 'hsqsv2-layer-two\n' >"$work_dir/layer-2.squashfs"

python3 "$fixture_tool" context \
	--build-context "$repo_root/update/examples/build-context-v1.json" \
	--base "$work_dir/base.squashfs" \
	--output-dir "$work_dir/context-1"
context_one=$work_dir/context-1/build-context.json
base_generation=$work_dir/context-1/base-generation.json

"$generation_tool" publish \
	--state "$state" \
	--generation "$base_generation" \
	--object "$context_one" \
	--object "$work_dir/base.squashfs" \
	--activate \
	--expected-current none >/dev/null
base_digest=$(canonical_digest "$base_generation")

python3 "$fixture_tool" layer \
	--generation-version 2 \
	--build-context "$context_one" \
	--build-spec "$work_dir/context-1/build-spec.json" \
	--acquisition "$work_dir/context-1/acquisition.json" \
	--parent "$base_generation" \
	--changed-paths "$repo_root/update/examples/layer-paths-v1.json" \
	--tombstones "$repo_root/update/examples/tombstones-v1.json" \
	--layer "$work_dir/layer-1.squashfs" \
	--output-dir "$work_dir/generation-1"

common_one=(
	--object "$context_one"
	--object "$work_dir/context-1/build-spec.json"
	--object "$work_dir/context-1/source-catalog.json"
	--object "$work_dir/context-1/acquisition.json"
	--object "$repo_root/update/examples/layer-paths-v1.json"
	--object "$repo_root/update/examples/tombstones-v1.json"
	--object "$work_dir/layer-1.squashfs"
	--object "$work_dir/generation-1/transaction.json"
	--object "$work_dir/generation-1/portage-state.json"
)
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-1/generation.json" \
	"${common_one[@]}" \
	--activate \
	--expected-current "$base_digest" >/dev/null
generation_one=$(canonical_digest "$work_dir/generation-1/generation.json")

jq '
	.config_digest = ("sha256:" + ("a" * 64))
	| .sources[0].revision = ("b" * 40)
	| .sources[0].tree_digest = ("sha256:" + ("b" * 64))
	| .target.profile_revision = ("b" * 40)
	| .toolchain.portage_version = "3.0.78"
	| .toolchain.digest = ("sha256:" + ("d" * 64))
' "$context_one" |
	"$manifest_tool" canonicalize - >"$work_dir/context-2-input.json"

expect_failure "generation v1 requires an unchanged build context" \
	"$manifest_tool" verify-update-context \
	"$base_generation" \
	"$work_dir/context-2-input.json"
"$manifest_tool" verify-update-context \
	"$work_dir/generation-1/generation.json" \
	"$work_dir/context-2-input.json" \
	"$work_dir/generation-1/portage-state.json" >/dev/null

python3 "$fixture_tool" context \
	--build-context "$work_dir/context-2-input.json" \
	--base "$work_dir/base.squashfs" \
	--output-dir "$work_dir/context-2"
context_two=$work_dir/context-2/build-context.json
result_world=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
python3 "$fixture_tool" layer \
	--generation-version 2 \
	--result-world-digest "$result_world" \
	--build-context "$context_two" \
	--build-spec "$work_dir/context-2/build-spec.json" \
	--acquisition "$work_dir/context-2/acquisition.json" \
	--parent "$work_dir/generation-1/generation.json" \
	--changed-paths "$repo_root/update/examples/layer-paths-v1.json" \
	--tombstones "$repo_root/update/examples/tombstones-v1.json" \
	--layer "$work_dir/layer-2.squashfs" \
	--output-dir "$work_dir/generation-2"

common_two=(
	--object "$context_two"
	--object "$work_dir/context-2/build-spec.json"
	--object "$work_dir/context-2/source-catalog.json"
	--object "$work_dir/context-2/acquisition.json"
	--object "$repo_root/update/examples/layer-paths-v1.json"
	--object "$repo_root/update/examples/tombstones-v1.json"
	--object "$work_dir/layer-2.squashfs"
	--object "$work_dir/generation-2/transaction.json"
)
expect_failure "is missing or unsafe" \
	"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-2/generation.json" \
	"${common_two[@]}"

"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-2/generation.json" \
	"${common_two[@]}" \
	--object "$work_dir/generation-2/portage-state.json" \
	--activate \
	--expected-current "$generation_one" >/dev/null
generation_two=$(canonical_digest "$work_dir/generation-2/generation.json")

inspection=$(
	"$generation_tool" inspect --state "$state" "$generation_two"
)
jq -e \
	--arg parent "$generation_one" \
	--arg world "$result_world" \
	'
		.schema == "org.volatoo.generation/v2"
		and .parent_generation_digest == $parent
		and .portage_state_digest != null
		and .portage_state.world_digest == $world
		and .layer_count == 2
	' <<<"$inspection" >/dev/null ||
	fail "generation v2 inspection does not expose its parent and state"
jq -e \
	--arg world "$result_world" \
	'
		.world_digest == $world
		and .config_digest == ("sha256:" + ("a" * 64))
		and .repositories[0].revision == ("b" * 40)
		and .profile.revision == ("b" * 40)
		and .toolchain.portage_version == "3.0.78"
		and .toolchain.digest == ("sha256:" + ("d" * 64))
	' "$work_dir/generation-2/portage-state.json" >/dev/null ||
	fail "PortageState did not capture the complete transition"

gc=$("$generation_tool" gc --state "$state")
jq -e \
	--arg parent "$generation_one" \
	'
		.reachable_generations >= 3
		and (.roots | index($parent)) != null
	' <<<"$gc" >/dev/null ||
	fail "generation v2 parent chain is not retained by GC"

mkdir "$work_dir/compacted"
"$generation_tool" compact-manifest \
	--state "$state" \
	--generation "$generation_two" \
	--base "$work_dir/base.squashfs" \
	--context-output "$work_dir/compacted/build-context.json" \
	--output "$work_dir/compacted/generation.json" >/dev/null
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/compacted/generation.json" \
	--object "$work_dir/compacted/build-context.json" \
	--object "$work_dir/base.squashfs" \
	--activate \
	--expected-current "$generation_two" >/dev/null
compacted_inspection=$(
	"$generation_tool" inspect --state "$state" current
)
jq -e \
	--arg state_digest \
	"$(jq -r '.portage_state_digest' <<<"$inspection")" \
	'
		.schema == "org.volatoo.generation/v2"
		and .parent_generation_digest == null
		and .portage_state_digest == $state_digest
		and .layer_count == 0
	' <<<"$compacted_inspection" >/dev/null ||
	fail "compaction did not preserve generation v2 desired state"

[[ $base_digest != "$generation_one" ]] ||
	fail "v1 to v2 migration did not change generation identity"
[[ $generation_one != "$generation_two" ]] ||
	fail "Portage transition did not change generation identity"

echo "Volatoo generation v2 transition tests passed"
