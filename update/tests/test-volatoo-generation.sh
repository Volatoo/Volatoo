#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tool=$repo_root/update/volatoo-generation
manifest=$repo_root/update/volatoo-manifest
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-generation-test.XXXXXX")

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
	python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

print("sha256:" + hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

canonical_digest()
{
	"$manifest" digest "$1"
}

state=$work_dir/state
system=$state/volatoo/system
mkdir -p \
	"$state/volatoo/config" \
	"$state/volatoo/data/bind" \
	"$state/volatoo/data/identity" \
	"$state/volatoo/data/overlay" \
	"$state/volatoo/data/sync" \
	"$state/volatoo/snapshots"
printf '1\n' >"$state/volatoo/layout-version"
"$tool" migrate-state --state "$state"
grep -qx '1' "$state/volatoo/layout-version" ||
	fail "state migration changed the top-level layout version"
grep -qx '1' "$system/layout-version" ||
	fail "state migration did not publish system layout version 1"

"$manifest" canonicalize \
	"$repo_root/update/examples/build-context-v1.json" \
	>"$work_dir/context.json"
context_digest=$(canonical_digest "$work_dir/context.json")

printf 'hsqsbase-generation-fixture\n' >"$work_dir/base.squashfs"
base_digest=$(raw_digest "$work_dir/base.squashfs")
base_size=$(wc -c <"$work_dir/base.squashfs" | tr -d ' ')

make_generation()
{
	local number=$1
	local removed_path=$2
	local layer=$work_dir/layer-$number.squashfs
	local tombstones=$work_dir/tombstones-$number.json
	local transaction=$work_dir/transaction-$number.json
	local generation=$work_dir/generation-$number.json
	local layer_digest
	local layer_size
	local tombstones_digest
	local transaction_digest

	printf 'hsqslayer-generation-fixture-%s\n' "$number" >"$layer"
	layer_digest=$(raw_digest "$layer")
	layer_size=$(wc -c <"$layer" | tr -d ' ')
	jq -n \
		--arg path "$removed_path" \
		'{
		  schema: "org.volatoo.tombstones/v1",
		  target_id: "volatoo/amd64/glibc/openrc/23.0/base-v1",
		  paths: [$path]
		}' |
		"$manifest" canonicalize - >"$tombstones"
	tombstones_digest=$(canonical_digest "$tombstones")

	jq \
		--arg target 'volatoo/amd64/glibc/openrc/23.0/base-v1' \
		--arg context_digest "$context_digest" \
		--arg rootfs_digest "$layer_digest" \
		--argjson rootfs_size "$layer_size" \
		--arg tombstones_digest "$tombstones_digest" \
		'
		.target_id = $target
		| .build_context_digest = $context_digest
		| .filesystem.rootfs_digest = $rootfs_digest
		| .filesystem.rootfs_size = $rootfs_size
		| .filesystem.tombstones_digest = $tombstones_digest
		| .filesystem.tombstones_count = 1
		' \
		"$repo_root/update/examples/layer-transaction-v1.json" |
		"$manifest" canonicalize - >"$transaction"
	transaction_digest=$(canonical_digest "$transaction")

	jq -n \
		--arg context_digest "$context_digest" \
		--arg base_digest "$base_digest" \
		--argjson base_size "$base_size" \
		--arg layer_digest "$layer_digest" \
		--argjson layer_size "$layer_size" \
		--arg tombstones_digest "$tombstones_digest" \
		--arg transaction_digest "$transaction_digest" \
		'{
		  schema: "org.volatoo.generation/v1",
		  target_id: "volatoo/amd64/glibc/openrc/23.0/base-v1",
		  build_context_digest: $context_digest,
		  base: {
		    rootfs_digest: $base_digest,
		    rootfs_size: $base_size,
		    format: "squashfs"
		  },
		  layers: [{
		    rootfs_digest: $layer_digest,
		    rootfs_size: $layer_size,
		    format: "squashfs",
		    tombstones_digest: $tombstones_digest,
		    transaction_digest: $transaction_digest
		  }]
		}' |
		"$manifest" canonicalize - >"$generation"
}

make_generation 1 /etc/obsolete-one
make_generation 2 '/usr/share/obsolete two'

publish()
{
	local number=$1
	"$tool" publish \
		--state "$state" \
		--generation "$work_dir/generation-$number.json" \
		--object "$work_dir/context.json" \
		--object "$work_dir/base.squashfs" \
		--object "$work_dir/layer-$number.squashfs" \
		--object "$work_dir/tombstones-$number.json" \
		--object "$work_dir/transaction-$number.json" \
		"${@:2}"
}

publish 1 --activate
generation_one=$(canonical_digest "$work_dir/generation-1.json")
[[ $("$tool" resolve --state "$state") == "$generation_one" ]] ||
	fail "first generation was not selected"

publish 2 --activate
generation_two=$(canonical_digest "$work_dir/generation-2.json")
[[ $(<"$system/current") == "$generation_two" ]] ||
	fail "second generation is not current"
[[ $(<"$system/previous") == "$generation_one" ]] ||
	fail "first generation is not previous"

"$tool" pin --state "$state" rollback-safe previous
[[ $(<"$system/pins/rollback-safe") == "$generation_one" ]] ||
	fail "pin did not retain the selected previous generation"
jq -e \
	--arg digest "$generation_two" \
	--arg role current \
	'.generation_digest == $digest
	 and (.roles | index($role)) != null
	 and .layer_count == 1
	 and .valid == true' \
	< <("$tool" inspect --state "$state") >/dev/null ||
	fail "generation inspection is incomplete"
"$tool" list --state "$state" |
	grep -F "$generation_one" |
	grep -F 'pin:rollback-safe' >/dev/null ||
	fail "generation listing did not expose the pin"

printf 'orphan object\n' >"$work_dir/orphan"
orphan_digest=$(raw_digest "$work_dir/orphan")
cp "$work_dir/orphan" \
	"$system/objects/sha256/${orphan_digest#sha256:}"
jq -e \
	'.mode == "dry-run" and .garbage.objects == 1' \
	< <("$tool" gc --state "$state") >/dev/null ||
	fail "garbage collection dry-run did not find the orphan"
[[ -f $system/objects/sha256/${orphan_digest#sha256:} ]] ||
	fail "garbage collection dry-run deleted an object"
"$tool" gc --state "$state" --delete |
	jq -e '.mode == "delete" and .garbage.objects == 1' >/dev/null ||
	fail "garbage collection did not report the deletion"
[[ ! -e $system/objects/sha256/${orphan_digest#sha256:} ]] ||
	fail "garbage collection did not delete the orphan"
"$tool" unpin --state "$state" rollback-safe
[[ ! -e $system/pins/rollback-safe ]] ||
	fail "unpin did not remove the pin"

"$tool" rollback --state "$state"
[[ $(<"$system/current") == "$generation_one" ]] ||
	fail "rollback did not select the first generation"
[[ $(<"$system/previous") == "$generation_two" ]] ||
	fail "rollback did not retain the second generation"

# This is the safe intermediate state if power is lost after updating previous
# but before atomically replacing current: current remains bootable.
printf '%s\n' "$generation_one" >"$system/previous"
[[ $("$tool" resolve --state "$state") == "$generation_one" ]] ||
	fail "interrupted selection did not preserve current"

"$tool" select --state "$state" "$generation_two"
layer_two_digest=$(raw_digest "$work_dir/layer-2.squashfs")
layer_two_object=$system/objects/sha256/${layer_two_digest#sha256:}
chmod u+w "$layer_two_object"
printf 'corrupt\n' >"$layer_two_object"
fallback=$("$tool" resolve --state "$state" 2>"$work_dir/fallback.stderr")
[[ $fallback == "$generation_one" ]] ||
	fail "corrupt current generation did not fall back to previous"
grep -q 'selected previous' "$work_dir/fallback.stderr" ||
	fail "fallback was not reported"

"$tool" select --state "$state" "$generation_one" \
	2>"$work_dir/recover.stderr"
grep -q 'preserving previous' "$work_dir/recover.stderr" ||
	fail "select did not report corrupt-current recovery"
[[ $(<"$system/current") == "$generation_one" ]] ||
	fail "select did not recover from corrupt current"
[[ $(<"$system/previous") == "$generation_one" ]] ||
	fail "select replaced a valid previous with corrupt current"

current_before=$(<"$system/current")
make_generation 3 /etc/obsolete-three
if "$tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-3.json" \
	--object "$work_dir/context.json" \
	--object "$work_dir/base.squashfs" \
	--activate \
	>"$work_dir/incomplete.stdout" 2>"$work_dir/incomplete.stderr"; then
	fail "incomplete closure was accepted"
fi
[[ $(<"$system/current") == "$current_before" ]] ||
	fail "failed publication changed current"

echo "volatoo generation tests passed"
