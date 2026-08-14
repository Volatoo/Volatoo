#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tool=$repo_root/update/volatoo-generation
manifest=$repo_root/update/volatoo-manifest
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
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
[[ -d $system/realizations && ! -L $system/realizations ]] ||
	fail "state migration did not publish the realization directory"

printf 'hsqsbase-generation-fixture\n' >"$work_dir/base.squashfs"
python3 "$fixture_tool" context \
	--build-context "$repo_root/update/examples/build-context-v1.json" \
	--base "$work_dir/base.squashfs" \
	--output-dir "$work_dir/provenance"
context=$work_dir/provenance/build-context.json
build_spec=$work_dir/provenance/build-spec.json
source_catalog=$work_dir/provenance/source-catalog.json
acquisition=$work_dir/provenance/acquisition.json
base_generation=$work_dir/provenance/base-generation.json

"$tool" publish \
	--state "$state" \
	--generation "$base_generation" \
	--object "$context" \
	--object "$work_dir/base.squashfs" \
	--activate \
	--expected-current none
generation_zero=$(canonical_digest "$base_generation")
[[ $("$tool" resolve --state "$state") == "$generation_zero" ]] ||
	fail "base generation was not selected"

make_generation()
{
	local number=$1
	local removed_path=$2
	local parent=$3
	local layer=$work_dir/layer-$number.squashfs
	local tombstones=$work_dir/tombstones-$number.json
	local changed=$work_dir/changed-$number.json
	local output=$work_dir/layer-$number

	printf 'hsqslayer-generation-fixture-%s\n' "$number" >"$layer"
	jq -n \
		--arg path "$removed_path" \
		'{
		  schema: "org.volatoo.tombstones/v1",
		  target_id: "volatoo/amd64/glibc/openrc/23.0/base-v1",
		  paths: [$path]
		}' |
		"$manifest" canonicalize - >"$tombstones"
	jq -n \
		--arg path "/etc/volatoo-generation-$number" \
		'{
		  schema: "org.volatoo.layer-paths/v1",
		  target_id: "volatoo/amd64/glibc/openrc/23.0/base-v1",
		  paths: [$path]
		}' |
		"$manifest" canonicalize - >"$changed"

	python3 "$fixture_tool" layer \
		--build-context "$context" \
		--build-spec "$build_spec" \
		--acquisition "$acquisition" \
		--parent "$parent" \
		--changed-paths "$changed" \
		--tombstones "$tombstones" \
		--layer "$layer" \
		--output-dir "$output"
}

publish()
{
	local number=$1
	local expected_current=$2
	"$tool" publish \
		--state "$state" \
		--generation "$work_dir/layer-$number/generation.json" \
		--object "$context" \
		--object "$build_spec" \
		--object "$source_catalog" \
		--object "$acquisition" \
		--object "$work_dir/base.squashfs" \
		--object "$work_dir/layer-$number.squashfs" \
		--object "$work_dir/changed-$number.json" \
		--object "$work_dir/tombstones-$number.json" \
		--object "$work_dir/layer-$number/transaction.json" \
		--activate \
		--expected-current "$expected_current"
}

make_generation 1 /etc/obsolete-one "$base_generation"
publish 1 "$generation_zero"
generation_one=$(canonical_digest "$work_dir/layer-1/generation.json")
[[ $("$tool" resolve --state "$state") == "$generation_one" ]] ||
	fail "first generation was not selected"

make_generation 2 '/usr/share/obsolete two' \
	"$work_dir/layer-1/generation.json"
publish 2 "$generation_one"
generation_two=$(canonical_digest "$work_dir/layer-2/generation.json")
[[ $(<"$system/current") == "$generation_two" ]] ||
	fail "second generation is not current"
[[ $(<"$system/previous") == "$generation_one" ]] ||
	fail "first generation is not previous"
if "$tool" select \
	--state "$state" \
	"$generation_one" \
	>"$work_dir/unconditional.stdout" \
	2>"$work_dir/unconditional.stderr"; then
	fail "unconditional generation selection was accepted"
fi
grep -q 'select requires --expected-current' \
	"$work_dir/unconditional.stderr" ||
	fail "unconditional generation selection was not diagnosed"

"$tool" pin --state "$state" rollback-safe previous
[[ $(<"$system/pins/rollback-safe") == "$generation_one" ]] ||
	fail "pin did not retain the selected previous generation"
jq -e \
	--arg digest "$generation_two" \
	--arg role current \
	'.generation_digest == $digest
	 and (.boot_plan_digest | startswith("sha256:"))
	 and (.roles | index($role)) != null
	 and .layer_count == 2
	 and .valid == true' \
	< <("$tool" inspect --state "$state") >/dev/null ||
	fail "generation inspection is incomplete"
"$tool" list --state "$state" |
	grep -F "$generation_one" |
	grep -F 'pin:rollback-safe' >/dev/null ||
	fail "generation listing did not expose the pin"

realization_state=$work_dir/realization-state
cp -a "$state" "$realization_state"
realization_system=$realization_state/volatoo/system
realization_plan_digest=$(
	"$tool" inspect --state "$realization_state" "$generation_two" |
		jq -r '.boot_plan_digest'
)
if "$tool" select \
	--state "$realization_state" \
	--expected-current "$generation_two" \
	--require-realization \
	"$generation_two" \
	>"$work_dir/unrealized-select.stdout" \
	2>"$work_dir/unrealized-select.stderr"; then
	fail "required realization was not enforced"
fi
grep -q 'generation has no realized closure' \
	"$work_dir/unrealized-select.stderr" ||
	fail "missing realization was not diagnosed"

printf 'hsqsrealized-generation-fixture\n' \
	>"$work_dir/realized.squashfs"
realization_tree_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if "$tool" record-realization \
	--state "$realization_state" \
	--generation "$generation_two" \
	--boot-plan-digest \
		sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
	--rootfs "$work_dir/realized.squashfs" \
	--tree-digest "$realization_tree_digest" \
	--fhs-contract org.volatoo.gentoo-fhs/v1 \
	>"$work_dir/wrong-realization-plan.stdout" \
	2>"$work_dir/wrong-realization-plan.stderr"; then
	fail "realization accepted a stale boot plan"
fi
grep -q 'boot plan changed before realization publication' \
	"$work_dir/wrong-realization-plan.stderr" ||
	fail "stale realization boot plan was not diagnosed"
[[ ! -e $realization_system/realizations/${generation_two#sha256:} ]] ||
	fail "failed realization publication created a binding"

if "$tool" record-realization \
	--state "$realization_state" \
	--generation "$generation_two" \
	--boot-plan-digest "$realization_plan_digest" \
	--rootfs "$work_dir/realized.squashfs" \
	--tree-digest "$realization_tree_digest" \
	--fhs-contract org.volatoo.gentoo-fhs/v2 \
	>"$work_dir/wrong-fhs.stdout" \
	2>"$work_dir/wrong-fhs.stderr"
then
	fail "realization accepted an unsupported FHS contract"
fi
grep -q 'unsupported FHS contract' "$work_dir/wrong-fhs.stderr" ||
	fail "unsupported realization FHS contract was not diagnosed"
[[ ! -e $realization_system/realizations/${generation_two#sha256:} ]] ||
	fail "failed FHS contract publication created a binding"

verity_state=$work_dir/verity-state
cp -a "$state" "$verity_state"
verity_system=$verity_state/volatoo/system
verity_plan_digest=$(
	"$tool" inspect --state "$verity_state" "$generation_two" |
		jq -r '.boot_plan_digest'
)
dd if=/dev/zero of="$work_dir/verity-root.squashfs" \
	bs=4096 count=1 2>/dev/null
printf 'hsqs' |
	dd of="$work_dir/verity-root.squashfs" \
		bs=1 count=4 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$work_dir/verity-hash.bin" \
	bs=4096 count=1 2>/dev/null
verity_root_hash=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
verity_salt=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
if "$tool" record-realization \
	--state "$verity_state" \
	--generation "$generation_two" \
	--boot-plan-digest "$verity_plan_digest" \
	--rootfs "$work_dir/verity-root.squashfs" \
	--tree-digest "$realization_tree_digest" \
	--fhs-contract org.volatoo.gentoo-fhs/v1 \
	--verity-hash "$work_dir/verity-hash.bin" \
	>"$work_dir/incomplete-verity.stdout" \
	2>"$work_dir/incomplete-verity.stderr"; then
	fail "incomplete verity realization arguments were accepted"
fi
grep -q 'all verity realization arguments must be provided together' \
	"$work_dir/incomplete-verity.stderr" ||
	fail "incomplete verity realization was not diagnosed"
[[ ! -e $verity_system/realizations/${generation_two#sha256:} ]] ||
	fail "incomplete verity realization created a binding"

"$tool" record-realization \
	--state "$verity_state" \
	--generation "$generation_two" \
	--boot-plan-digest "$verity_plan_digest" \
	--rootfs "$work_dir/verity-root.squashfs" \
	--tree-digest "$realization_tree_digest" \
	--fhs-contract org.volatoo.gentoo-fhs/v1 \
	--verity-hash "$work_dir/verity-hash.bin" \
	--verity-root-hash "$verity_root_hash" \
	--verity-salt "$verity_salt" \
	--verity-data-blocks 1
verity_inspection=$(
	"$tool" inspect --state "$verity_state" "$generation_two"
)
jq -e \
	--arg root_hash "$verity_root_hash" \
	--arg salt "$verity_salt" \
	'.realization.contract_version == 2
	 and .realization.verity.root_hash == $root_hash
	 and .realization.verity.salt == $salt
	 and .realization.verity.data_blocks == 1
	 and .realization.verity.data_block_size == 4096
	 and .realization.verity.hash_block_size == 4096
	 and .realization.verity.superblock == false
	 and (.realization.verity.hash_digest | startswith("sha256:"))' \
	<<<"$verity_inspection" >/dev/null ||
	fail "generation inspection did not expose realization-v2 verity metadata"
verity_plan=$verity_system/objects/sha256/$(
	jq -r '.realization.realization_digest' <<<"$verity_inspection" |
		cut -d: -f2
)
grep -qx 'VOLATOO_REALIZATION_V2' "$verity_plan" ||
	fail "verity realization did not use the v2 contract"
jq -e \
	'.schema == "org.volatoo.system-scrub/v1"
	 and .status == "verified"
	 and .roots >= 2
	 and .generations >= 2
	 and .objects > 0' \
	< <("$tool" scrub --state "$verity_state") >/dev/null ||
	fail "reachable generation scrub did not report a verified closure"
verity_hash_object=$verity_system/objects/sha256/$(
	jq -r '.realization.verity.hash_digest' <<<"$verity_inspection" |
		cut -d: -f2
)
chmod u+w "$verity_hash_object"
printf 'corrupt verity hash object\n' >"$verity_hash_object"
if "$tool" scrub \
	--state "$verity_state" \
	>"$work_dir/corrupt-scrub.stdout" \
	2>"$work_dir/corrupt-scrub.stderr"; then
	fail "scrub accepted a corrupt verity hash object"
fi
grep -q 'object digest mismatch' "$work_dir/corrupt-scrub.stderr" ||
	fail "scrub did not diagnose the corrupt verity hash object"
verity_fallback=$(
	"$tool" resolve \
		--state "$verity_state" \
		2>"$work_dir/verity-fallback.stderr"
)
[[ $verity_fallback == "$generation_one" ]] ||
	fail "corrupt verity tree did not fall back to previous"
grep -q 'selected previous' "$work_dir/verity-fallback.stderr" ||
	fail "verity-tree fallback was not reported"

"$tool" record-realization \
	--state "$realization_state" \
	--generation "$generation_two" \
	--boot-plan-digest "$realization_plan_digest" \
	--rootfs "$work_dir/realized.squashfs" \
	--tree-digest "$realization_tree_digest" \
	--fhs-contract org.volatoo.gentoo-fhs/v1
realization_inspection=$(
	"$tool" inspect --state "$realization_state" "$generation_two"
)
jq -e \
	--arg tree "$realization_tree_digest" \
	'.realized == true
	 and .realization.tree_digest == $tree
	 and .realization.fhs_contract == "org.volatoo.gentoo-fhs/v1"
	 and (.realization.realization_digest | startswith("sha256:"))
	 and (.realization.rootfs_digest | startswith("sha256:"))' \
	<<<"$realization_inspection" >/dev/null ||
	fail "generation inspection did not expose the realized closure"
"$tool" select \
	--state "$realization_state" \
	--expected-current "$generation_two" \
	--require-realization \
	"$generation_two" >/dev/null

if command -v signify >/dev/null 2>&1; then
	signify -G -n \
		-p "$work_dir/release.pub" \
		-s "$work_dir/release.sec"
	signify -G -n \
		-p "$work_dir/rotated.pub" \
		-s "$work_dir/rotated.sec"
	signify -G -n \
		-p "$work_dir/untrusted.pub" \
		-s "$work_dir/untrusted.sec"

	if "$tool" select \
		--state "$realization_state" \
		--expected-current "$generation_two" \
		--require-realization \
		--require-signature \
		--trusted-key "$work_dir/release.pub" \
		"$generation_two" \
		>"$work_dir/unsigned-select.stdout" \
		2>"$work_dir/unsigned-select.stderr"; then
		fail "required realization signature was not enforced"
	fi
	grep -q 'no signature from a trusted public key' \
		"$work_dir/unsigned-select.stderr" ||
		fail "missing realization signature was not diagnosed"

	"$tool" sign-realization \
		--state "$realization_state" \
		--generation "$generation_two" \
		--secret-key "$work_dir/release.sec" \
		--trusted-key "$work_dir/release.pub"
	"$tool" sign-realization \
		--state "$realization_state" \
		--generation "$generation_two" \
		--secret-key "$work_dir/release.sec" \
		--trusted-key "$work_dir/release.pub" >/dev/null
	release_key_digest=$(raw_digest "$work_dir/release.pub")
	jq -e \
		--arg key "$release_key_digest" \
		'.realization.signatures
		 | length == 1 and .[0].key_id == $key' \
		< <("$tool" inspect \
			--state "$realization_state" \
			"$generation_two") >/dev/null ||
		fail "generation inspection did not expose its realization signature"
	"$tool" select \
		--state "$realization_state" \
		--expected-current "$generation_two" \
		--require-realization \
		--require-signature \
		--trusted-key "$work_dir/release.pub" \
		"$generation_two" >/dev/null

	if "$tool" select \
		--state "$realization_state" \
		--expected-current "$generation_two" \
		--require-realization \
		--require-signature \
		--trusted-key "$work_dir/untrusted.pub" \
		"$generation_two" \
		>"$work_dir/wrong-key.stdout" \
		2>"$work_dir/wrong-key.stderr"; then
		fail "untrusted realization key was accepted"
	fi
	grep -q 'no signature from a trusted public key' \
		"$work_dir/wrong-key.stderr" ||
		fail "untrusted realization key was not diagnosed"

	"$tool" sign-realization \
		--state "$realization_state" \
		--generation "$generation_two" \
		--secret-key "$work_dir/rotated.sec" \
		--trusted-key "$work_dir/rotated.pub" \
		--activate \
		--expected-current "$generation_two"
	rotated_key_digest=$(raw_digest "$work_dir/rotated.pub")
	jq -e \
		--arg first "$release_key_digest" \
		--arg second "$rotated_key_digest" \
		'.realization.signatures
		 | length == 2
		 and (map(.key_id) | index($first)) != null
		 and (map(.key_id) | index($second)) != null' \
		< <("$tool" inspect \
			--state "$realization_state" \
			"$generation_two") >/dev/null ||
		fail "realization key rotation signatures were not retained"
	"$tool" select \
		--state "$realization_state" \
		--expected-current "$generation_two" \
		--require-signature \
		--trusted-key "$work_dir/rotated.pub" \
		"$generation_two" >/dev/null

	realization_digest=$(
		jq -r '.realization.realization_digest' \
			< <("$tool" inspect \
				--state "$realization_state" \
				"$generation_two")
	)
	jq -e \
		'.status == "verified" and .trusted_signatures == 1' \
		< <("$tool" scrub \
			--state "$realization_state" \
			--trusted-key "$work_dir/release.pub") >/dev/null ||
		fail "scrub did not verify the reachable realization signature"
	fake_realization=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
	mkdir "$realization_system/signatures/$fake_realization"
	cp \
		"$realization_system/signatures/${realization_digest#sha256:}/${release_key_digest#sha256:}.sig" \
		"$realization_system/signatures/$fake_realization/${release_key_digest#sha256:}.sig"
	jq -e \
		'.mode == "delete" and .garbage.signatures == 1' \
		< <("$tool" gc --state "$realization_state" --delete) >/dev/null ||
		fail "garbage collection did not remove an unreachable signature"
	[[ ! -e $realization_system/signatures/$fake_realization ]] ||
		fail "unreachable realization signature directory survived collection"

	signature_tamper_state=$work_dir/signature-tamper-state
	cp -a "$realization_state" "$signature_tamper_state"
	signature_tamper_system=$signature_tamper_state/volatoo/system
	signature_path=$signature_tamper_system/signatures/${realization_digest#sha256:}/${release_key_digest#sha256:}.sig
	printf 'different message\n' >"$work_dir/different-message"
	signify -S \
		-s "$work_dir/release.sec" \
		-m "$work_dir/different-message" \
		-x "$work_dir/different-message.sig"
	chmod u+w "$signature_path"
	cp "$work_dir/different-message.sig" "$signature_path"
	if "$tool" select \
		--state "$signature_tamper_state" \
		--expected-current "$generation_two" \
		--require-signature \
		--trusted-key "$work_dir/release.pub" \
		"$generation_two" \
		>"$work_dir/tampered-signature.stdout" \
		2>"$work_dir/tampered-signature.stderr"; then
		fail "signature over a different realization was accepted"
	fi
	grep -q 'realization signature.*failed' \
		"$work_dir/tampered-signature.stderr" ||
		fail "tampered realization signature was not diagnosed"
fi

realization_layer_two=$realization_system/objects/sha256/$(
	raw_digest "$work_dir/layer-2.squashfs" |
		cut -d: -f2
)
chmod u+w "$realization_layer_two"
printf 'corrupt realized input\n' >"$realization_layer_two"
[[ $("$tool" resolve --state "$realization_state") == "$generation_two" ]] ||
	fail "realized generation still depended on its source layer at selection"
realized_rootfs_digest=$(
	jq -r '.realization.rootfs_digest' <<<"$realization_inspection"
)
realized_rootfs=$realization_system/objects/sha256/${realized_rootfs_digest#sha256:}
chmod u+w "$realized_rootfs"
printf 'corrupt realized rootfs\n' >"$realized_rootfs"
realization_fallback=$(
	"$tool" resolve \
		--state "$realization_state" \
		2>"$work_dir/realization-fallback.stderr"
)
[[ $realization_fallback == "$generation_one" ]] ||
	fail "corrupt realized closure did not fall back to previous"
grep -q 'selected previous' "$work_dir/realization-fallback.stderr" ||
	fail "realized closure fallback was not reported"

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

"$tool" select \
	--state "$state" \
	--expected-current "$generation_one" \
	"$generation_two"
layer_two_digest=$(raw_digest "$work_dir/layer-2.squashfs")
layer_two_object=$system/objects/sha256/${layer_two_digest#sha256:}
chmod u+w "$layer_two_object"
printf 'corrupt\n' >"$layer_two_object"
fallback=$("$tool" resolve --state "$state" 2>"$work_dir/fallback.stderr")
[[ $fallback == "$generation_one" ]] ||
	fail "corrupt current generation did not fall back to previous"
grep -q 'selected previous' "$work_dir/fallback.stderr" ||
	fail "fallback was not reported"

"$tool" select \
	--state "$state" \
	--expected-current "$generation_two" \
	"$generation_one" \
	2>"$work_dir/recover.stderr"
grep -q 'preserving previous' "$work_dir/recover.stderr" ||
	fail "select did not report corrupt-current recovery"
[[ $(<"$system/current") == "$generation_one" ]] ||
	fail "select did not recover from corrupt current"
[[ $(<"$system/previous") == "$generation_one" ]] ||
	fail "select replaced a valid previous with corrupt current"

current_before=$(<"$system/current")
make_generation 3 /etc/obsolete-three \
	"$work_dir/layer-1/generation.json"

fake_digest=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
jq --arg digest "$fake_digest" \
	'.build_spec_digest = $digest' \
	"$work_dir/layer-3/transaction.json" |
	"$manifest" canonicalize - >"$work_dir/missing-provenance-transaction.json"
missing_transaction_digest=$(
	canonical_digest "$work_dir/missing-provenance-transaction.json"
)
jq --arg digest "$missing_transaction_digest" \
	'.layers[-1].transaction_digest = $digest' \
	"$work_dir/layer-3/generation.json" |
	"$manifest" canonicalize - >"$work_dir/missing-provenance-generation.json"
if "$tool" publish \
	--state "$state" \
	--generation "$work_dir/missing-provenance-generation.json" \
	--object "$work_dir/missing-provenance-transaction.json" \
	>"$work_dir/incomplete.stdout" 2>"$work_dir/incomplete.stderr"; then
	fail "incomplete closure was accepted"
fi
[[ $(<"$system/current") == "$current_before" ]] ||
	fail "failed publication changed current"

jq --arg digest "$generation_zero" \
	'.parent_generation_digest = $digest' \
	"$work_dir/layer-3/transaction.json" |
	"$manifest" canonicalize - >"$work_dir/wrong-parent-transaction.json"
wrong_parent_transaction_digest=$(
	canonical_digest "$work_dir/wrong-parent-transaction.json"
)
jq --arg digest "$wrong_parent_transaction_digest" \
	'.layers[-1].transaction_digest = $digest' \
	"$work_dir/layer-3/generation.json" |
	"$manifest" canonicalize - >"$work_dir/wrong-parent-generation.json"
if "$tool" publish \
	--state "$state" \
	--generation "$work_dir/wrong-parent-generation.json" \
	--object "$work_dir/layer-3.squashfs" \
	--object "$work_dir/changed-3.json" \
	--object "$work_dir/tombstones-3.json" \
	--object "$work_dir/wrong-parent-transaction.json" \
	>"$work_dir/wrong-parent.stdout" 2>"$work_dir/wrong-parent.stderr"; then
	fail "wrong transaction parent was accepted"
fi
grep -q 'transaction parent does not match' "$work_dir/wrong-parent.stderr" ||
	fail "wrong transaction parent was not diagnosed"

if "$tool" publish \
	--state "$state" \
	--generation "$work_dir/layer-3/generation.json" \
	--object "$context" \
	--object "$build_spec" \
	--object "$source_catalog" \
	--object "$acquisition" \
	--object "$work_dir/base.squashfs" \
	--object "$work_dir/layer-3.squashfs" \
	--object "$work_dir/changed-3.json" \
	--object "$work_dir/tombstones-3.json" \
	--object "$work_dir/layer-3/transaction.json" \
	--activate \
	--expected-current "$generation_two" \
	>"$work_dir/stale.stdout" 2>"$work_dir/stale.stderr"; then
	fail "stale expected-current activation was accepted"
fi
grep -q 'current generation changed before selection' \
	"$work_dir/stale.stderr" ||
	fail "stale activation was not diagnosed"
[[ $(<"$system/current") == "$current_before" ]] ||
	fail "stale activation changed current"

printf 'hsqsdifferent-base\n' >"$work_dir/different-base.squashfs"
different_base_digest=$(raw_digest "$work_dir/different-base.squashfs")
different_base_size=$(
	wc -c <"$work_dir/different-base.squashfs" |
		tr -d ' '
)
jq \
	--arg digest "$different_base_digest" \
	--argjson size "$different_base_size" \
	'.base.rootfs_digest = $digest | .base.rootfs_size = $size' \
	"$base_generation" |
	"$manifest" canonicalize - >"$work_dir/wrong-base-generation.json"
if "$tool" publish \
	--state "$state" \
	--generation "$work_dir/wrong-base-generation.json" \
	--object "$work_dir/different-base.squashfs" \
	>"$work_dir/wrong-base.stdout" 2>"$work_dir/wrong-base.stderr"; then
	fail "generation base differing from its build context was accepted"
fi
grep -q 'base rootfs_digest does not match build context' \
	"$work_dir/wrong-base.stderr" ||
	fail "build context/base mismatch was not diagnosed"

echo "volatoo generation tests passed"
